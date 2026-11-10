// Original implementation. Captures completed playback mixer output, never opens an input session.
#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <dlfcn.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <errno.h>
#include <sys/time.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#define SLOTS 16
#define MAX_FRAMES 2048
struct Packet { uint32_t rate,channels,frames; float samples[MAX_FRAMES*2]; };
static struct Packet queue[SLOTS];
static unsigned head,tail;
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static volatile int active;
static OSStatus (*original)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32,AudioBufferList*);
static OSStatus render(AudioUnit unit,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *data){
 OSStatus status=original(unit,flags,time,bus,frames,data);
 if(!__sync_fetch_and_add(&active,0)||status||!data||!frames||frames>MAX_FRAMES)return status;
 AudioComponentDescription desc={0};AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit),&desc);
 if(desc.componentSubType!='mcmx')return status;
 AudioStreamBasicDescription fmt={0};UInt32 size=sizeof(fmt);
 if(AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,bus,&fmt,&size)||fmt.mFormatID!='lpcm'||!(fmt.mFormatFlags&kAudioFormatFlagIsFloat)||fmt.mBitsPerChannel!=32||fmt.mChannelsPerFrame<1||fmt.mChannelsPerFrame>2||fmt.mSampleRate<8000||fmt.mSampleRate>96000)return status;
 unsigned channels=fmt.mChannelsPerFrame;int planar=(fmt.mFormatFlags&kAudioFormatFlagIsNonInterleaved)!=0;
 if(data->mNumberBuffers<(planar?channels:1))return status;
 for(unsigned c=0;c<(planar?channels:1);c++)if(!data->mBuffers[c].mData||data->mBuffers[c].mDataByteSize<frames*4*(planar?1:channels))return status;
 if(pthread_mutex_trylock(&mutex))return status; // Never wait on the audio thread.
 unsigned next=(head+1)%SLOTS;
 if(next!=tail){struct Packet *p=&queue[head];p->rate=(uint32_t)fmt.mSampleRate;p->channels=channels;p->frames=frames;
 for(unsigned f=0;f<frames;f++)for(unsigned c=0;c<channels;c++){float v=((float*)data->mBuffers[planar?c:0].mData)[planar?f:f*channels+c];p->samples[f*channels+c]=isfinite(v)?v:0;}
 head=next;}
 pthread_mutex_unlock(&mutex);return status;
}
static int sendall(int fd,const void *data,size_t count){const char *p=data;while(count){ssize_t n=send(fd,p,count,0);if(n<=0)return -1;p+=n;count-=n;}return 0;}
static void *serve(void *unused){
 int server=socket(AF_INET,SOCK_STREAM,0),one=1;if(server<0)return 0;
 setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
 struct sockaddr_in address={0};address.sin_len=sizeof(address);address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);address.sin_port=htons(5903);
 if(bind(server,(struct sockaddr*)&address,sizeof(address))||listen(server,1)){close(server);return 0;}
 while(1){int fd=accept(server,0,0);if(fd<0)continue;
 setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
 struct timeval timeout={2,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));timeout.tv_sec=0;timeout.tv_usec=250000;setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
 char hello[4];if(recv(fd,hello,4,MSG_WAITALL)!=4||memcmp(hello,"IMA1",4)){close(fd);continue;}
 pthread_mutex_lock(&mutex);head=tail=0;__sync_lock_test_and_set(&active,1);pthread_mutex_unlock(&mutex);
 if(sendall(fd,"IMA1",4)){__sync_lock_test_and_set(&active,0);close(fd);continue;}
 while(1){struct Packet packet;int available=0;
 pthread_mutex_lock(&mutex);if(head!=tail){packet=queue[tail];tail=(tail+1)%SLOTS;available=1;}pthread_mutex_unlock(&mutex);
 char probe;ssize_t alive=recv(fd,&probe,1,MSG_PEEK|MSG_DONTWAIT);if(alive==0 || (alive<0 && errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR))break;
 if(!available){usleep(2000);continue;}
 uint32_t header[4]={htonl(packet.rate),htonl(packet.channels),htonl(packet.frames),htonl(packet.frames*packet.channels*4)};
 if(sendall(fd,header,sizeof(header))||sendall(fd,packet.samples,packet.frames*packet.channels*4))break;
 }
 pthread_mutex_lock(&mutex);__sync_lock_test_and_set(&active,0);head=tail=0;pthread_mutex_unlock(&mutex);close(fd);
 }
 return 0;
}
__attribute__((constructor)) static void start(void){void *h=dlopen("/usr/lib/libsubstrate.dylib",RTLD_LAZY);void (*hook)(void*,void*,void**)=dlsym(h,"MSHookFunction");if(!hook)return;hook((void*)AudioUnitRender,(void*)render,(void**)&original);pthread_t thread;if(!pthread_create(&thread,0,serve,0))pthread_detach(thread);}
