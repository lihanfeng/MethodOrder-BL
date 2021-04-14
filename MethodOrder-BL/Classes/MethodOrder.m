//
//  LaunMethodOrder.m
//  LaunMethodOrder-BL
//
//  Created by hanfeng on 2021/4/13.
//

#import "MethodOrder.h"
#import <dlfcn.h>
#import <libkern/OSAtomicQueue.h>
#import <pthread.h>

static OSQueueHead queue = OS_ATOMIC_QUEUE_INIT;

static BOOL collectFinished = NO;
static BOOL sInitDidOccur = NO;

typedef struct {
    void *pc;
    void *next;
} PCNode;

// The guards are [start, stop).
// This function will be called at least once per DSO and may be called
// more than once with the same values of start/stop.
void __sanitizer_cov_trace_pc_guard_init(uint32_t *start,
                                         uint32_t *stop) {
    sInitDidOccur = YES;
    static uint32_t N;  // Counter for the guards.
    if (start == stop || *start) return;  // Initialize only once.
    for (uint32_t *x = start; x < stop; x++)
        *x = ++N;  // Guards should start from 1.
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    if (collectFinished || (!*guard && sInitDidOccur)) {
        return;
    }

    // If you set *guard to 0 this code will not be called again for this edge.
    *guard = 0;
    void *PC = __builtin_return_address(0);
    PCNode *node = malloc(sizeof(PCNode));
    *node = (PCNode){PC, NULL};
    OSAtomicEnqueue(&queue, node, offsetof(PCNode, next));
}

extern void StartMethodOrder(void(^completion)(NSString *orderFilePath)) {
    collectFinished = YES;
    __sync_synchronize();
    NSString *functionExclude = [NSString stringWithFormat:@"_%s", __FUNCTION__];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray <NSString *> *functions = [NSMutableArray array];
        while (YES) {
            PCNode *node = OSAtomicDequeue(&queue, offsetof(PCNode, next));
            if (node == NULL) {
                break;
            }
            Dl_info info = {0};
            dladdr(node->pc, &info);
            if (info.dli_sname) {
                NSString *name = @(info.dli_sname);
                BOOL isObjc = [name hasPrefix:@"+["] || [name hasPrefix:@"-["];
                NSString *symbolName = isObjc ? name : [@"_" stringByAppendingString:name];
                [functions addObject:symbolName];
            }
        }
        if (functions.count == 0) {
            if (completion) {
                completion(nil);
            }
            return;
        }
        
        NSMutableSet *callSets = [NSMutableSet set];
        NSMutableArray<NSString *> *calls = [NSMutableArray arrayWithCapacity:functions.count];
        NSEnumerator *enumerator = [functions reverseObjectEnumerator];
        NSString *Function;
        while (Function = [enumerator nextObject]) {
            if (![callSets containsObject:Function]) {
                [calls addObject:Function];
                [callSets addObject:Function];
            }
        }
        [calls removeObject:functionExclude];
        NSString *result = [calls componentsJoinedByString:@"\n"];
#if DEBUG
        NSLog(@"App Method Order:\n%@", result);
#endif
        NSString *filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"app.order"];
        NSData *fileContents = [result dataUsingEncoding:NSUTF8StringEncoding];
        BOOL success = [[NSFileManager defaultManager] createFileAtPath:filePath
                                                               contents:fileContents
                                                             attributes:nil];
        if (completion) {
            completion(success ? filePath : nil);
        }
    });
}
