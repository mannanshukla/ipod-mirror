// Multitouch for iPod Mirror. Loaded into SpringBoard by MobileSubstrate (see iPodMirrorTouch.plist).
// Veency's RFB pointer can only carry one finger, so the Mac sends multi-finger frames here instead.
// Events are built the way Veency 0.9.3500 builds its single touch on iOS 5 (GraphicsServices "level 3"
// layout), with one path per finger, and are sent to the client port of the window under the first finger.
// Listens on device loopback 5904 only; the Mac reaches it through usbmux. Protocol: Docs/PROTOCOL.md.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <stdlib.h>
#include <mach/mach_time.h>

enum{MaxFingers=5,PhaseBegan=1,PhaseMoved=2,PhaseEnded=3,PhaseCancelled=4};
enum{EventHand=0x0bb9,HandDown=0x1,HandDragged=0x2,HandUp=0x6,HandCancel=0x8};

struct GSRecord {uint32_t type,subType;CGPoint locationOnScreen,locationInWindow;uint32_t windowContextId;uint64_t timestamp;uint32_t zero,modifierFlags;uint16_t eventNumber,x2a;uint32_t size;};
struct GSHand {uint32_t type;uint16_t x34,x38;CGPoint x3a;uint32_t x40;};
struct GSPath {uint8_t x00,x01,x02,x03;uint32_t x04,x08;CGPoint position;uint32_t x14;};
struct GSInfo {struct GSHand hand;uint32_t x44,x48,x4c;uint8_t x50,pathPositions;uint16_t x52;struct GSPath path[MaxFingers];};
struct TouchEvent {struct GSRecord record;struct GSInfo info;};
// The iOS armv7 ABI aligns 64-bit fields to 4 bytes; these offsets are the ones GraphicsServices reads.
_Static_assert(offsetof(struct GSRecord,timestamp)==0x1c&&sizeof(struct GSRecord)==0x34,"GSEventRecord layout");
_Static_assert(sizeof(struct GSHand)==0x14&&offsetof(struct GSInfo,x52)==0x22&&offsetof(struct GSInfo,path)==0x24&&sizeof(struct GSPath)==0x18,"hand/path layout");

static void (*SendEvent)(struct GSRecord*,mach_port_t);
static uint64_t (*EventTimestamp)(void);
static mach_port_t (*SystemPort)(void);
// Screen size in points (portrait) and scale. Written by the main-thread measurement, read by connections.
static pthread_mutex_t screenLock=PTHREAD_MUTEX_INITIALIZER;
static CGFloat scale=2,width=320,height=480;
static int measured,measuring; // measuring: a measurement block is queued, so no connection queues another.

static mach_port_t portAt(CGPoint p){
 Class server=objc_getClass("CAWindowServer");if(!server)return 0;
 id s=((id(*)(id,SEL))objc_msgSend)(server,sel_registerName("serverIfRunning"));if(!s)return 0;
 NSArray *displays=((id(*)(id,SEL))objc_msgSend)(s,sel_registerName("displays"));if(![displays count])return 0;
 return ((mach_port_t(*)(id,SEL,CGPoint))objc_msgSend)([displays objectAtIndex:0],sel_registerName("clientPortAtPosition:"),p);
}
static void inject(mach_port_t port,uint32_t handType,int count,const CGPoint *points,int touching){
 struct TouchEvent e;memset(&e,0,sizeof(e));
 e.record.type=EventHand;e.record.locationInWindow=points[0];e.record.timestamp=EventTimestamp();
 e.record.size=(uint32_t)(offsetof(struct GSInfo,path)+count*sizeof(struct GSPath));
 e.info.hand.type=handType;e.info.hand.x34=count;e.info.hand.x38=touching?count:0;e.info.x52=count;
 for(int i=0;i<count;i++){struct GSPath *p=&e.info.path[i];p->x00=i+1;p->x01=i+2;p->x02=touching?3:0;p->position=points[i];}
 if(port)SendEvent(&e.record,port);
}
static mach_timebase_info_data_t base; // Filled once in the constructor, before any connection thread runs.
static double monotonic(void){
 return (double)mach_absolute_time()*base.numer/base.denom/1e9;
}
// Reads exactly n bytes; each recv wakes at least every 250 ms (SO_RCVTIMEO). With deadline 0, returns Idle
// if nothing has arrived yet so the caller can keep waiting. Otherwise returns -1 on EOF, error, or once the
// monotonic deadline passes, so a frame trickled in byte by byte cannot hold touches open.
enum{Idle=-2};
static int readAll(int fd,void *buf,size_t n,double deadline){
 char *p=buf;size_t got=0;
 while(got<n){
  ssize_t r=recv(fd,p+got,n-got,0);
  if(r>0){got+=r;}
  else if(r<0&&(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR)){if(!got&&deadline==0)return Idle;}
  else return -1;
  if(deadline>0&&monotonic()>deadline)return -1; // Also rejects a read that completes late.
 }
 return 0;
}
// UIScreen is not usable while SpringBoard is still launching (the constructor runs before main), so the
// screen is measured on the main thread when the first client connects.
static void measureScreen(void){
 pthread_mutex_lock(&screenLock);int skip=measured||measuring;measuring=1;pthread_mutex_unlock(&screenLock);if(skip)return;
 dispatch_semaphore_t finished=dispatch_semaphore_create(0);
 dispatch_retain(finished); // Owned by the block, which may outlive this wait.
 dispatch_async(dispatch_get_main_queue(),^{
  Class screen=objc_getClass("UIScreen");
  id main=screen?((id(*)(id,SEL))objc_msgSend)(screen,sel_registerName("mainScreen")):nil;
  if(main){
   CGFloat s=1;if([main respondsToSelector:@selector(scale)])s=((CGFloat(*)(id,SEL))objc_msgSend)(main,sel_registerName("scale"));
   CGRect bounds=CGRectZero;((void(*)(CGRect*,id,SEL))objc_msgSend_stret)(&bounds,main,sel_registerName("bounds"));
   pthread_mutex_lock(&screenLock);
   if(s>=1&&s<=4)scale=s;
   if(bounds.size.width>0&&bounds.size.height>0){width=MIN(bounds.size.width,bounds.size.height);height=MAX(bounds.size.width,bounds.size.height);}
   measured=1;pthread_mutex_unlock(&screenLock);
  }
  pthread_mutex_lock(&screenLock);measuring=0;pthread_mutex_unlock(&screenLock);
  dispatch_semaphore_signal(finished);dispatch_release(finished);
 });
 // If SpringBoard's main thread is stuck, answer with the current values (iPod touch 4 defaults) rather than hang.
 dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));dispatch_release(finished);
}
// One gesture at a time across all connections. Every injection happens under gestureLock, and only the
// connection that began the current gesture may move, end or cancel it. A newer connection's "began" first
// cancels whatever gesture is down, so an old connection's late frames or cleanup can never touch the new one.
static pthread_mutex_t gestureLock=PTHREAD_MUTEX_INITIALIZER;
static struct {unsigned owner;int down,count;mach_port_t target;CGPoint last[MaxFingers];} gesture;
static unsigned nextConnection,current; // current: the newest accepted connection; only it may begin or drive a gesture.
static int ownsDown(unsigned me){pthread_mutex_lock(&gestureLock);int r=gesture.down&&gesture.owner==me;pthread_mutex_unlock(&gestureLock);return r;}
static void cancelIfOwner(unsigned me){
 pthread_mutex_lock(&gestureLock);
 if(gesture.down&&gesture.owner==me){inject(gesture.target,HandCancel,gesture.count,gesture.last,0);gesture.down=0;}
 pthread_mutex_unlock(&gestureLock);
}
static void handle(unsigned me,int phase,int n,const CGPoint *pixels,CGFloat sc){
 CGPoint p[MaxFingers];for(int i=0;i<n;i++)p[i]=CGPointMake(pixels[i].x/sc,pixels[i].y/sc);
 pthread_mutex_lock(&gestureLock);
 if(me!=current){pthread_mutex_unlock(&gestureLock);return;} // Replaced: frames already parsed are dropped.
 if(phase==PhaseBegan){
  if(gesture.down)inject(gesture.target,HandCancel,gesture.count,gesture.last,0);
  // Like Veency, hit-test in screen pixels; the event itself carries points.
  mach_port_t target=portAt(pixels[0]);if(!target&&SystemPort)target=SystemPort();
  gesture.owner=me;gesture.target=target;gesture.down=1;inject(target,HandDown,n,p,1);
 }
 else if(!gesture.down||gesture.owner!=me||n!=gesture.count){pthread_mutex_unlock(&gestureLock);return;} // Not our gesture, or a changed finger count.
 else if(phase==PhaseMoved)inject(gesture.target,HandDragged,n,p,1);
 else {inject(gesture.target,phase==PhaseEnded?HandUp:HandCancel,n,p,0);gesture.down=0;}
 gesture.count=n;memcpy(gesture.last,p,sizeof(CGPoint)*n);
 pthread_mutex_unlock(&gestureLock);
}
static void serve(int fd,unsigned me){
 char hello[4];if(readAll(fd,hello,4,monotonic()+5)||memcmp(hello,"IMT1",4))return;
 measureScreen();
 pthread_mutex_lock(&screenLock);CGFloat sc=scale;int pw=(int)(width*scale),ph=(int)(height*scale);pthread_mutex_unlock(&screenLock);
 // Coordinates on the wire are portrait screen pixels.
 uint8_t reply[12]={'I','M','T','1',pw>>8,pw&255,ph>>8,ph&255,MaxFingers,0,0,0};if(send(fd,reply,12,0)!=12)return;
 double lastFrame=monotonic();
 while(1){
  uint8_t h[4];int r=readAll(fd,h,1,0);
  if(r==Idle){if(ownsDown(me)&&monotonic()-lastFrame>=3)break;continue;} // Our fingers are down and no frame for 3 s: the Mac stalled.
  if(r||h[0]!='T')break;
  // The rest of a frame must arrive within 2 s, and never after the 3 s limit for fingers held without a frame.
  double deadline=monotonic()+2;if(ownsDown(me)&&lastFrame+3<deadline)deadline=lastFrame+3;
  if(readAll(fd,h+1,3,deadline))break;
  int phase=h[1],n=h[2];if(h[3]||n<1||n>MaxFingers||phase<PhaseBegan||phase>PhaseCancelled)break;
  uint8_t raw[MaxFingers*4];if(readAll(fd,raw,n*4,deadline))break;
  CGPoint pixels[MaxFingers];
  for(int i=0;i<n;i++)pixels[i]=CGPointMake(MIN(((raw[i*4]<<8)|raw[i*4+1]),pw-1),MIN(((raw[i*4+2]<<8)|raw[i*4+3]),ph-1));
  handle(me,phase,n,pixels,sc);lastFrame=monotonic();
 }
 cancelIfOwner(me); // Never leave fingers on the screen when the Mac goes away.
}
// The newest connection replaces any older one (shut down, so its serve() cancels its touches and exits).
static pthread_mutex_t activeLock=PTHREAD_MUTEX_INITIALIZER;
static int activeFd=-1;
struct Connection {int fd;unsigned id;};
static void *connection(void *arg){
 struct Connection c=*(struct Connection*)arg;free(arg);int fd=c.fd;
 NSAutoreleasePool *pool=[NSAutoreleasePool new];serve(fd,c.id);[pool drain];
 pthread_mutex_lock(&activeLock);if(activeFd==fd)activeFd=-1;close(fd);pthread_mutex_unlock(&activeLock);
 return 0;
}
static void *listener(void *unused){
 int server=socket(AF_INET,SOCK_STREAM,0),one=1;if(server<0)return 0;setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
 struct sockaddr_in addr={0};addr.sin_len=sizeof(addr);addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);addr.sin_port=htons(5904);
 if(bind(server,(struct sockaddr*)&addr,sizeof(addr))||listen(server,2)){close(server);return 0;}
 while(1){
  int fd=accept(server,0,0);if(fd<0){usleep(200000);continue;}
  struct timeval timeout={0,250000};
  setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
  setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));timeout.tv_sec=2;timeout.tv_usec=0;setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
  struct Connection *c=malloc(sizeof(*c));if(!c){close(fd);continue;}
  pthread_mutex_lock(&gestureLock);c->fd=fd;c->id=current=++nextConnection;pthread_mutex_unlock(&gestureLock); // Older connections lose the right to act now.
  pthread_mutex_lock(&activeLock);if(activeFd>=0)shutdown(activeFd,SHUT_RDWR);activeFd=fd;pthread_mutex_unlock(&activeLock);
  pthread_t thread;pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED);
  if(pthread_create(&thread,&attr,connection,c)){free(c);pthread_mutex_lock(&activeLock);if(activeFd==fd)activeFd=-1;close(fd);pthread_mutex_unlock(&activeLock);}
  pthread_attr_destroy(&attr);
 }
 return 0;
}
__attribute__((constructor)) static void start(void){
 Dl_info self;if(dladdr((void*)&start,&self))dlopen(self.dli_fname,RTLD_NOW|RTLD_NODELETE); // The listener thread runs this image's code forever.
 void *gs=dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",RTLD_LAZY);if(!gs)return;
 SendEvent=dlsym(gs,"GSSendEvent");EventTimestamp=dlsym(gs,"GSCurrentEventTimestamp");SystemPort=dlsym(gs,"GSGetPurpleSystemEventPort");
 // Only the layout above is known to work: GraphicsServices "level 3" (iOS 4/5, before backboardd).
 if(!SendEvent||!EventTimestamp||!dlsym(gs,"GSLibraryCopyGenerationInfoValueForKey"))return;
 if(mach_timebase_info(&base)!=KERN_SUCCESS||!base.denom)return;
 pthread_t thread;pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED);
 pthread_create(&thread,&attr,listener,0);pthread_attr_destroy(&attr);
}
