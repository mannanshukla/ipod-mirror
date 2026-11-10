#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <sys/time.h>
static double now(void){struct timeval t;gettimeofday(&t,0);return t.tv_sec+t.tv_usec/1e6;}
int main(){NSAutoreleasePool *p=[NSAutoreleasePool new];
 const char *paths[]={"/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface","/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer","/System/Library/Frameworks/QuartzCore.framework/QuartzCore","/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",0};
 for(int i=0;paths[i];i++)dlopen(paths[i],RTLD_LAZY|RTLD_GLOBAL);
 const char *symbols[]={"UIGetScreenImage","CARenderServerRenderDisplay","IOSurfaceCreate","IOSurfaceLock","IOSurfaceGetBaseAddress","IOMobileFramebufferGetMainDisplay","IOMobileFramebufferGetLayerDefaultSurface","AudioUnitRender","AudioUnitAddRenderNotify",0};
 for(int i=0;symbols[i];i++)printf("%s: %s\n",symbols[i],dlsym(RTLD_DEFAULT,symbols[i])?"available":"missing");
 CGImageRef (*capture)(void)=dlsym(RTLD_DEFAULT,"UIGetScreenImage");
 if(capture){double start=now();int n=0;for(int i=0;i<30;i++){CGImageRef image=capture();if(image){if(!i)printf("Screen: %zux%zu\n",CGImageGetWidth(image),CGImageGetHeight(image));CGImageRelease(image);n++;}}printf("Capture-only: %d frames, %.1f ms/frame\n",n,(now()-start)*1000/30);}
 [p drain];return 0;}
