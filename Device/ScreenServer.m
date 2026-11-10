#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <sys/time.h>
#include <unistd.h>
#include <signal.h>
static int sendall(int fd,const void *data,size_t n){const char *p=data;while(n){ssize_t sent=send(fd,p,n,0);if(sent<=0)return -1;p+=sent;n-=sent;}return 0;}
static double now(void){struct timeval t;gettimeofday(&t,0);return t.tv_sec+t.tv_usec/1e6;}
int main(){NSAutoreleasePool *pool=[NSAutoreleasePool new];signal(SIGPIPE,SIG_IGN);
 CGImageRef (*capture)(void)=dlsym(RTLD_DEFAULT,"UIGetScreenImage");if(!capture)return 2;
 const int w=320,h=480;void *pixels=calloc(w*h,4);CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();CGContextRef context=CGBitmapContextCreate(pixels,w,h,8,w*4,color,kCGImageAlphaNoneSkipLast|kCGBitmapByteOrder32Big);CGColorSpaceRelease(color);if(!context)return 3;
 int server=socket(AF_INET,SOCK_STREAM,0),one=1;setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
 struct sockaddr_in addr={0};addr.sin_len=sizeof(addr);addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);addr.sin_port=htons(5902);
 if(bind(server,(struct sockaddr*)&addr,sizeof(addr))||listen(server,1))return 4;
 while(1){int fd=accept(server,0,0);if(fd<0)continue;setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));struct timeval timeout={2,0};setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));timeout.tv_sec=10;setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
 while(1){char request[4];if(recv(fd,request,4,MSG_WAITALL)!=4||memcmp(request,"FRAM",4))break;NSAutoreleasePool *framePool=[NSAutoreleasePool new];double start=now();CGImageRef shot=capture();if(!shot){[framePool drain];break;}
 CFDataRef raw=CGDataProviderCopyData(CGImageGetDataProvider(shot));
 size_t sw=CGImageGetWidth(shot),sh=CGImageGetHeight(shot),stride=CGImageGetBytesPerRow(shot);CGBitmapInfo info=CGImageGetBitmapInfo(shot);
 if(raw && CGImageGetBitsPerPixel(shot)==32 && CFDataGetLength(raw)>=stride*sh && ((info&kCGBitmapByteOrderMask)==kCGBitmapByteOrder32Little)){
 const unsigned char *src=CFDataGetBytePtr(raw);unsigned char *dst=pixels;
 for(int y=0;y<h;y++)for(int x=0;x<w;x++){const unsigned char *q=src+(y*sh/h)*stride+(x*sw/w)*4;unsigned char *o=dst+(y*w+x)*4;o[0]=q[2];o[1]=q[1];o[2]=q[0];o[3]=255;}
 }else{CGContextSetInterpolationQuality(context,kCGInterpolationNone);CGContextDrawImage(context,CGRectMake(0,0,w,h),shot);}
 if(raw)CFRelease(raw);CGImageRelease(shot);
 uint32_t header[5]={htonl(0x494d5631),htonl(w),htonl(h),htonl(w*h*4),htonl((uint32_t)((now()-start)*1000000))};
 int result=sendall(fd,header,sizeof(header))||sendall(fd,pixels,w*h*4);[framePool drain];if(result)break;
 }close(fd);}
 CGContextRelease(context);free(pixels);close(server);[pool drain];return 0;}
