#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <os/proc.h>

#import "CocoMemoryGuard.h"
#import "environ.h"

typedef NS_ENUM(int, CocoMemoryLevel) {
    CocoMemoryLevelNormal = 0,
    CocoMemoryLevelWarning = 1,
    CocoMemoryLevelCritical = 2
};

static dispatch_source_t gTimer;
static dispatch_queue_t gQueue;
static CocoMemoryLevel gLevel = CocoMemoryLevelNormal;
static int gPeakMB = 0;
static int gTicks = 0;
static CFAbsoluteTime gLastJavaGC = 0;

static int CocoGuardFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (int)(info.phys_footprint >> 20);
}

// Full GC through JNI from this (non-Java) thread. The JVM pointer is set in
// JNI_OnLoad (input_bridge_v3.m); nothing is done before the VM exists.
static void CocoGuardJavaGC(void) {
    JavaVM *vm = runtimeJavaVMPtr;
    if (vm == NULL) {
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gLastJavaGC != 0 && now - gLastJavaGC < 60.0) {
        return;
    }
    gLastJavaGC = now;
    JNIEnv *env = NULL;
    BOOL attached = NO;
    jint got = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (got == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThreadAsDaemon(vm, &env, NULL) != JNI_OK) {
            return;
        }
        attached = YES;
    } else if (got != JNI_OK) {
        return;
    }
    jclass system = (*env)->FindClass(env, "java/lang/System");
    if (system != NULL) {
        jmethodID gc = (*env)->GetStaticMethodID(env, system, "gc", "()V");
        if (gc != NULL) {
            (*env)->CallStaticVoidMethod(env, system, gc);
        }
        (*env)->DeleteLocalRef(env, system);
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }
    if (attached) {
        (*vm)->DetachCurrentThread(vm);
    }
    NSLog(@"[CocoMem] Requested a Java GC, footprint now %d MB", CocoGuardFootprintMB());
}

static void CocoGuardRelieve(BOOL critical, int footprint, int limit) {
    NSLog(@"[CocoMem] %@: footprint %d MB of %d MB (%d%%)", critical ? @"CRITICAL" : @"warning",
        footprint, limit, limit > 0 ? footprint * 100 / limit : 0);
    malloc_zone_pressure_relief(NULL, 0);
    if (critical) {
        CocoGuardJavaGC();
    }
}

static void CocoGuardTick(void) {
    int footprint = CocoGuardFootprintMB();
    size_t available = os_proc_available_memory();
    if (footprint <= 0 || available == 0) {
        return;
    }
    int limit = footprint + (int)(available >> 20);
    int percent = footprint * 100 / limit;
    gPeakMB = MAX(gPeakMB, footprint);

    CocoMemoryLevel level = gLevel;
    if (percent >= 90) {
        level = CocoMemoryLevelCritical;
    } else if (percent >= 75) {
        level = MAX(level, CocoMemoryLevelWarning);
        if (level == CocoMemoryLevelCritical && percent < 80) {
            level = CocoMemoryLevelWarning;
        }
    } else if (percent < 65) {
        level = CocoMemoryLevelNormal;
    }
    if (level > gLevel) {
        CocoGuardRelieve(level == CocoMemoryLevelCritical, footprint, limit);
    } else if (level == CocoMemoryLevelCritical) {
        // Still critical: keep trying (the Java GC is limited to once a minute)
        CocoGuardRelieve(YES, footprint, limit);
    }
    gLevel = level;

    // Every 30 s a summary line in latestlog.txt
    if (++gTicks % 15 == 0) {
        NSLog(@"[CocoMem] footprint %d MB / limit %d MB (%d%%), peak %d MB", footprint, limit, percent, gPeakMB);
    }
}

void CocoMemoryGuardStart(void) {
    if (gTimer != nil) {
        return;
    }
    gQueue = dispatch_queue_create("coco.memoryguard", DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(gTimer, ^{
        CocoGuardTick();
    });
    dispatch_resume(gTimer);
    // iOS's own warning comes shortly before it closes the app
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(gQueue, ^{
            int footprint = CocoGuardFootprintMB();
            int limit = footprint + (int)(os_proc_available_memory() >> 20);
            NSLog(@"[CocoMem] iOS memory warning");
            gLevel = CocoMemoryLevelCritical;
            CocoGuardRelieve(YES, footprint, limit);
        });
    }];
    NSLog(@"[CocoMem] Memory guard started");
}
