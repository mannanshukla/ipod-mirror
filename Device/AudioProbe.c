#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
static OSStatus (*original)(AudioUnit,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32,AudioBufferList*);
static volatile int logged=0;
static OSStatus render(AudioUnit unit,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *data){
 OSStatus status=original(unit,flags,time,bus,frames,data);
 if(logged<12){AudioComponentDescription desc={0};AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit),&desc);AudioStreamBasicDescription format={0};UInt32 size=sizeof(format);AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,bus,&format,&size);
 int fd=open("/tmp/ipod-mirror-audio-probe.txt",O_WRONLY|O_CREAT|O_APPEND,0600);if(fd>=0){char line[256];int n=snprintf(line,sizeof(line),"unit=%08x status=%d frames=%u buffers=%u rate=%.0f format=%08x flags=%u channels=%u bits=%u\n",(unsigned)desc.componentSubType,(int)status,(unsigned)frames,data?(unsigned)data->mNumberBuffers:0,format.mSampleRate,(unsigned)format.mFormatID,(unsigned)format.mFormatFlags,(unsigned)format.mChannelsPerFrame,(unsigned)format.mBitsPerChannel);write(fd,line,n);close(fd);}logged++;}
 return status;
}
__attribute__((constructor)) static void start(void){
 void *h=dlopen("/usr/lib/libsubstrate.dylib",RTLD_LAZY);void (*hook)(void*,void*,void**)=dlsym(h,"MSHookFunction");
 if(hook){hook((void*)AudioUnitRender,(void*)render,(void**)&original);int fd=open("/tmp/ipod-mirror-audio-probe.txt",O_WRONLY|O_CREAT|O_APPEND,0600);if(fd>=0){write(fd,"probe loaded\n",13);close(fd);}}
}
