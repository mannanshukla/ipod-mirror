#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <sys/time.h>
#include <unistd.h>
#include <signal.h>
#include <notify.h>
#include <mach/mach.h>
// Memory rules for the 256 MB iPod touch 4: no per-frame allocation of frame-sized buffers.
// The screen is rendered into one IOSurface that lives for the whole connection; nothing is captured
// until a client connects, and buffers are released when it disconnects. Capture rate drops while the
// screen is unchanged or blanked. Wire protocol: client sends "FRAM", server replies with a 20-byte
// header (IMV1, 320, 480, bytes, capture microseconds) and 320x480 RGBA.
typedef void *IOSurfaceRef;
static IOSurfaceRef (*SurfaceCreate)(CFDictionaryRef);
static int (*SurfaceLock)(IOSurfaceRef,uint32_t,uint32_t*),(*SurfaceUnlock)(IOSurfaceRef,uint32_t,uint32_t*);
static void *(*SurfaceBase)(IOSurfaceRef);
static size_t (*SurfaceBytesPerRow)(IOSurfaceRef);
static void (*RenderDisplay)(mach_port_t,CFStringRef,IOSurfaceRef,int,int);
static CGImageRef (*ScreenImage)(void);
enum{W=320,H=480};
static const uint32_t Sentinel=0x00c0ffee;
static const double ActiveInterval=1.0/15,IdleInterval=0.25,BlankInterval=0.5;
static int sendall(int fd,const void *data,size_t n){const char *p=data;while(n){ssize_t sent=send(fd,p,n,0);if(sent<=0)return -1;p+=sent;n-=sent;}return 0;}
static double now(void){struct timeval t;gettimeofday(&t,0);return t.tv_sec+t.tv_usec/1e6;}
static void sleepUntil(double t){double d=t-now();if(d>BlankInterval)d=BlankInterval;if(d>0)usleep((useconds_t)(d*1e6));} // Clamped so a wall-clock jump can never stall past the client's 5 s deadline.
static CFNumberRef number(int v){return CFNumberCreate(0,kCFNumberIntType,&v);}
static IOSurfaceRef createSurface(int w,int h){
 if(!SurfaceCreate||!SurfaceLock||!SurfaceUnlock||!SurfaceBase||!SurfaceBytesPerRow||!RenderDisplay)return 0;
 CFNumberRef v[]={number(4),number(w*4),number(w),number(h),number('BGRA'),number(w*4*h)};
 const void *keys[]={CFSTR("IOSurfaceIsGlobal"),CFSTR("IOSurfaceBytesPerElement"),CFSTR("IOSurfaceBytesPerRow"),CFSTR("IOSurfaceWidth"),CFSTR("IOSurfaceHeight"),CFSTR("IOSurfacePixelFormat"),CFSTR("IOSurfaceAllocSize")};
 const void *values[]={kCFBooleanTrue,v[0],v[1],v[2],v[3],v[4],v[5]};
 CFDictionaryRef props=CFDictionaryCreate(0,keys,values,7,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 for(int i=0;i<6;i++)CFRelease(v[i]);
 IOSurfaceRef s=SurfaceCreate(props);CFRelease(props);return s;
}
// Downscale BGRA (little-endian 32-bit) into the RGBA output buffer in place; returns a content hash.
static uint32_t convert(const unsigned char *src,size_t sw,size_t sh,size_t stride,unsigned char *dst){
 uint32_t hash=2166136261u;
 for(int y=0;y<H;y++){const unsigned char *row=src+(y*sh/H)*stride;unsigned char *o=dst+y*W*4;
  for(int x=0;x<W;x++,o+=4){const unsigned char *q=row+(x*sw/W)*4;o[0]=q[2];o[1]=q[1];o[2]=q[0];o[3]=255;hash=(hash^*(const uint32_t*)q)*16777619u;}}
 return hash;
}
static uint32_t hashPixels(const unsigned char *p){uint32_t hash=2166136261u;const uint32_t *w=(const uint32_t*)p;for(int i=0;i<W*H;i+=7)hash=(hash^w[i])*16777619u;return hash;}
static void serve(int fd,int blankToken){
 // Learn the native screen size once per connection (one allocation, not per frame).
 size_t sw=640,sh=960;CGImageRef probe=ScreenImage?ScreenImage():0;
 if(probe){sw=CGImageGetWidth(probe);sh=CGImageGetHeight(probe);CGImageRelease(probe);}
 IOSurfaceRef surface=createSurface((int)sw,(int)sh);
 if(surface){ // Mark a few pixels; if they all survive the first render, the render server refused us and we fall back.
  SurfaceLock(surface,0,0);unsigned char *b=SurfaceBase(surface);size_t stride=SurfaceBytesPerRow(surface);for(int i=0;i<4;i++)*(uint32_t*)(b+(i*sh/4)*stride+(i*sw/4)*4)=Sentinel;SurfaceUnlock(surface,0,0);}
 unsigned char *pixels=calloc(W*H,4);CGContextRef context=0;
 if(!pixels){if(surface)CFRelease(surface);return;}
 int surfaceChecked=0,blanked=0;uint32_t lastHash=0;double interval=ActiveInterval,last=0;
 while(1){
  char request[4];if(recv(fd,request,4,MSG_WAITALL)!=4||memcmp(request,"FRAM",4))break;
  int state=0;uint64_t blank=0;if(blankToken>=0&&notify_get_state(blankToken,&blank)==NOTIFY_STATUS_OK)state=blank!=0;
  sleepUntil(last+(state?BlankInterval:interval));
  double start=now();last=start;
  if(state){ // Display is off: send black without touching the render server.
   if(!blanked){for(int i=0;i<W*H;i++)((uint32_t*)pixels)[i]=htonl(0x000000ff);blanked=1;}
  }else{
   blanked=0;uint32_t hash=0;int done=0;
   if(surface){
    RenderDisplay(0,CFSTR("LCD"),surface,0,0);
    SurfaceLock(surface,1,0);const unsigned char *b=SurfaceBase(surface);size_t stride=SurfaceBytesPerRow(surface);
    if(!surfaceChecked){int untouched=1;for(int i=0;i<4;i++)if(*(const uint32_t*)(b+(i*sh/4)*stride+(i*sw/4)*4)!=Sentinel)untouched=0;surfaceChecked=1;if(untouched){SurfaceUnlock(surface,1,0);CFRelease(surface);surface=0;}}
    if(surface){hash=convert(b,sw,sh,stride,pixels);SurfaceUnlock(surface,1,0);done=1;}
   }
   if(!done){ // Fallback: UIGetScreenImage drawn straight into a persistent context (no CFData copy).
    if(!context){CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();context=CGBitmapContextCreate(pixels,W,H,8,W*4,color,kCGImageAlphaNoneSkipLast|kCGBitmapByteOrder32Big);CGColorSpaceRelease(color);if(!context)break;CGContextSetInterpolationQuality(context,kCGInterpolationNone);}
    NSAutoreleasePool *framePool=[NSAutoreleasePool new];CGImageRef shot=ScreenImage?ScreenImage():0;
    if(shot){CGContextDrawImage(context,CGRectMake(0,0,W,H),shot);CGImageRelease(shot);}
    [framePool drain];if(!shot)break;hash=hashPixels(pixels);
   }
   // Back off while nothing changes; return to full rate on the first change.
   interval=hash==lastHash?(interval*2<IdleInterval?interval*2:IdleInterval):ActiveInterval;lastHash=hash;
  }
  uint32_t header[5]={htonl(0x494d5631),htonl(W),htonl(H),htonl(W*H*4),htonl((uint32_t)((now()-start)*1000000))};
  if(sendall(fd,header,sizeof(header))||sendall(fd,pixels,W*H*4))break;
 }
 if(context)CGContextRelease(context);free(pixels);if(surface)CFRelease(surface);
}
int main(){NSAutoreleasePool *pool=[NSAutoreleasePool new];signal(SIGPIPE,SIG_IGN);
 ScreenImage=dlsym(RTLD_DEFAULT,"UIGetScreenImage");
 void *ios=dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface",RTLD_LAZY),*qc=dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore",RTLD_LAZY);
 if(ios){SurfaceCreate=dlsym(ios,"IOSurfaceCreate");SurfaceLock=dlsym(ios,"IOSurfaceLock");SurfaceUnlock=dlsym(ios,"IOSurfaceUnlock");SurfaceBase=dlsym(ios,"IOSurfaceGetBaseAddress");SurfaceBytesPerRow=dlsym(ios,"IOSurfaceGetBytesPerRow");}
 if(qc)RenderDisplay=dlsym(qc,"CARenderServerRenderDisplay");
 if(!ScreenImage&&!RenderDisplay)return 0; // Nothing can capture on this OS; exit cleanly so launchd does not respawn.
 int blankToken=-1;if(notify_register_check("com.apple.springboard.hasBlankedScreen",&blankToken)!=NOTIFY_STATUS_OK)blankToken=-1;
 int server=socket(AF_INET,SOCK_STREAM,0),one=1;setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
 struct sockaddr_in addr={0};addr.sin_len=sizeof(addr);addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);addr.sin_port=htons(5902);
 if(bind(server,(struct sockaddr*)&addr,sizeof(addr))||listen(server,1))return 4;
 while(1){int fd=accept(server,0,0);if(fd<0){usleep(100000);continue;} // Blocks with no client: no capture, no polling.
  setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));struct timeval timeout={2,0};setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));timeout.tv_sec=10;setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
  serve(fd,blankToken);close(fd);}
 close(server);[pool drain];return 0;}
