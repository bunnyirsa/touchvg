//! \file GiViewAdapter.mm
//! \brief 实现iOS绘图视图适配器 GiViewAdapter
// Copyright (c) 2012-2014, https://github.com/rhcad/touchvg

#import "GiViewImpl.h"
#import "GiImageCache.h"
#include "giplaying.h"
#include <algorithm>

static NSString* const CAPTIONS[] = { nil, @"全选", @"重选", @"绘图", @"取消",
    @"删除", @"克隆", @"定长", @"不定长", @"锁定", @"解锁", @"编辑", @"返回",
    @"闭合", @"不闭合", @"加点", @"删点", @"成组", @"解组", @"翻转",
};
static NSString* const IMAGENAMES[] = { nil, @"vg_selall.png", nil, @"vg_draw.png",
    @"vg_back.png", @"vg_delete.png", @"vg_clone.png", @"vg_fixlen.png",
    @"vg_freelen.png", @"vg_lock.png", @"vg_unlock.png", @"vg_edit.png",
    @"vg_endedit.png", nil, nil, @"vg_addvertex.png", @"vg_delvertex.png",
    @"vg_group.png", @"vg_ungroup.png", @"vg_overturn.png",
};
NSString* EXTIMAGENAMES[41] = { nil };
static const int EXTRA_ACTION_BEGIN = 40;

static int getExtraImageCount() { int n = 0; while (EXTIMAGENAMES[n]) n++; return n; }

//! Button class for showContextActions().
@interface UIButtonAutoHide : UIButton
@property (nonatomic, WEAK) GiPaintView *delegate;
@end

@implementation UIButtonAutoHide
@synthesize delegate;

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    BOOL ret = [super pointInside:point withEvent:event];
    CGPoint pt = [self.window convertPoint:point fromView:self];
    
    [delegate ignoreTouch:pt :ret ? self : nil];
    
    return ret;
}

@end

#define APPENDSIZE sizeof(_appendIDs)/sizeof(_appendIDs[0])

GiViewAdapter::GiViewAdapter(GiPaintView *mainView, GiViewAdapter *refView)
    : _view(mainView), _dynview(nil), _buttons(nil), _buttonImages(nil)
    , _actionEnabled(true), _oldAppendCount(0), _regenCount(0), _render(nil)
{
    if (refView) {
        _core = GiCoreView::createMagnifierView(this, refView->coreView(), refView);
        _lock = [refView->_lock RETAIN];
    } else {
        _core = GiCoreView::createView(this);
        _lock = [[NSRecursiveLock alloc] init];
    }
    memset(&respondsTo, 0, sizeof(respondsTo));
    memset(&_queues, 0, sizeof(_queues));
    _imageCache = [[GiImageCache alloc]init];
    
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        _render = [[GiLayerRender alloc]initWithAdapter:this];
    }
    
    for (int i = 0; i < APPENDSIZE; i++)
        _appendIDs[i] = 0;
}

GiViewAdapter::~GiViewAdapter() {
    [_buttons RELEASE];
    [_buttonImages RELEASE];
    [_imageCache RELEASE];
    [_render RELEASE];
    [_dynview RELEASE];
    [_lock RELEASE];
    _core->destoryView(this);
    _core->release();
}

void GiViewAdapter::clearCachedData() {
    [_buttonImages removeAllObjects];
    [_render clearCachedData];
    _core->clearCachedData();
}

int GiViewAdapter::getAppendCount() const {
    int n = 0;
    for (int i = 0; i < APPENDSIZE; i += 2) {
        if (_appendIDs[i] != 0) {
            n++;
        }
    }
    return n;
}

void GiViewAdapter::beginRender() {
    _oldAppendCount = getAppendCount();
}

bool GiViewAdapter::renderInContext(CGContextRef ctx) {
    if (_render) {
        if (![_render renderInContext:ctx]) {
            return false;
        }
        
        if (_oldAppendCount > 0) {
            for (int i = 0, j = _oldAppendCount * 2; i < APPENDSIZE; ) {
                _appendIDs[i++] = j < APPENDSIZE ? _appendIDs[j++] : 0;
                _appendIDs[i++] = j < APPENDSIZE ? _appendIDs[j++] : 0;
            }
            _oldAppendCount = 0;
        }
        [_render startRenderForPending];
    }
    else {
        long gs;
        mgvector<long> docs;
        
        @synchronized(locker()) {
            gs = _core->acquireFrontDocs(docs) ? _core->acquireGraphics(this) : 0;
        }
        if (!gs) {
            return false;
        }
        
        GiCanvasAdapter canvas(imageCache());
        if (canvas.beginPaint(ctx)) {
            _core->drawAll(docs, gs, &canvas);
            canvas.endPaint();
        }
        GiCoreView::releaseDocs(docs);
        _core->releaseGraphics(gs);
        for (int i = 0; i < APPENDSIZE; i++)
            _appendIDs[i] = 0;
        
        if (isMainThread() && ++_regenCount == 1) {
            onFirstRegen();
        }
    }
    [_dynview setNeedsDisplay];
    
    return true;
}

int GiViewAdapter::getAppendID(int index, long& playh) const {
    playh = 2 * index + 1 < APPENDSIZE ? _appendIDs[2 * index + 1] : 0;
    return index * 2 < APPENDSIZE ? (int)_appendIDs[2 * index] : 0;
}

struct ImageFinder : public MgFindImageCallback {
    NSString *srcPath;
    NSString *destPath;
    int count;
    
    ImageFinder(NSString *s, NSString *d) : srcPath(s), destPath(d) {}
    
    virtual void onFindImage(int sid, const char* name) {
        NSString *fileTitle = [NSString stringWithUTF8String:name];
        NSString *srcFile = [srcPath stringByAppendingPathComponent:fileTitle];
        NSString *destFile = [destPath stringByAppendingPathComponent:fileTitle];
        NSFileManager *fm = [NSFileManager defaultManager];
        
        if (![fm fileExistsAtPath:destFile]
            && [fm copyItemAtPath:srcFile toPath:destFile error:nil]) {
            NSLog(@"%d image files copied: %@", ++count, fileTitle);
        }
    }
};

struct RecordShapesCallback : MgStringCallback {
    GiViewAdapter* adapter;
    
    RecordShapesCallback(GiViewAdapter* adapter) : adapter(adapter) {}
    void onGetString(const char* filename) {
        GiCoreView* cv = adapter->coreView();
        NSDictionary *info = @{ @"tick" : [NSNumber numberWithLong:cv->getFrameTick()],
                                @"index" : [NSNumber numberWithInt:cv->getFrameIndex()],
                                @"flags" : [NSNumber numberWithInt:cv->getFrameFlags()],
                                @"filename" : [NSString stringWithUTF8String:filename],
                                @"view" : adapter->mainView() };
        adapter->onShapesRecorded(info);
    }
};

bool GiViewAdapter::startRecord(NSString *path, bool forUndo)
{
    int i = forUndo ? 0 : 1;
    if (_queues[i])
        return false;
    
    long doc = acquireFrontDoc();
    
    if (doc == 0) {
        NSLog(@"Fail to record shapes due to no front doc");
        return false;
    }
    if (!forUndo) {
        ImageFinder f(_imageCache.imagePath, path);
        _core->traverseImageShapes(doc, &f);
    }
    
    RecordShapesCallback c(this);
    if (!_core->startRecord([path UTF8String], doc, forUndo, getTickCount(),
                            !forUndo && hasShapesRecorded() ? &c : NULL)) {
        return false;
    }
    
    _queues[i] = dispatch_queue_create(forUndo ? "touchvg.undo" : "touchvg.record", NULL);
    _recordStopping[i] = false;
    
    return true;
}

void GiViewAdapter::undo() {
    if (_queues[0]) {
        _core->setCommand(_core->getCommand());
        dispatch_async(_queues[0], ^{
            @synchronized(locker()) {
                _core->undo(this);
            }
        });
    }
}

void GiViewAdapter::redo() {
    if (_queues[0]) {
        _core->setCommand(_core->getCommand());
        dispatch_async(_queues[0], ^{
            @synchronized(locker()) {
                _core->redo(this);
            }
        });
    }
}

void GiViewAdapter::stopRecord(bool forUndo)
{
    int i = forUndo ? 0 : 1;
    
    if (_queues[i]) {
        _recordStopping[i] = true;
        dispatch_async(_queues[i], ^{
            if (_core) {
                @synchronized(locker()) {
                    _core->stopRecord(forUndo);
                }
            }
        });
        dispatch_release(_queues[i]);
        _queues[i] = NULL;
    }
}

void GiViewAdapter::recordShapes(bool forUndo, long doc, long shapes)
{
    int i = forUndo ? 0 : 1;
    if ((doc || shapes) && _queues[i]) {
        long tick = _core->getRecordTick(forUndo, getTickCount());
        dispatch_async(_queues[i], ^{
            if (_view.window) {
                bool ret;
                if (!forUndo) {
                    RecordShapesCallback c(this);
                    ret = _core->recordShapes(forUndo, tick, doc, shapes, NULL,
                                              hasShapesRecorded() ? &c : NULL);
                } else {
                    ret = _core->recordShapes(forUndo, tick, doc, shapes);
                }
                if (!ret) {
                    NSLog(@"Fail to record shapes, forUndo=%d, doc=%ld, shapes=%ld", forUndo, doc, shapes);
                }
            }
        });
    }
}

void GiViewAdapter::regenAll(bool changed) {
    regen_(changed, 0, 0, _core->isUndoLoading());
}

int GiViewAdapter::regenLocked(bool changed, int sid, long playh, bool loading, long& doc0,
                               long& doc1, long& shapes1, long& gs, mgvector<long>*& docs)
{
    if (loading) {
        if (!_core->isPlaying()) {
            doc1 = _core->acquireFrontDoc();
            shapes1 = _core->acquireDynamicShapes();
        }
    } else if (changed || _regenCount == 0) {
        _core->submitBackDoc(this);
        if (changed) {
            _core->submitDynamicShapes(this);
            if (_queues[0]) {
                doc0 = _core->acquireFrontDoc();
            }
            if (_queues[1] && !_core->isPlaying()) {
                doc1 = _core->acquireFrontDoc();
                shapes1 = _core->acquireDynamicShapes();
            }
        }
    }
    
    if (sid) {
        for (int i = 0; i < APPENDSIZE; i += 2) {
            if (_appendIDs[i] == sid && _appendIDs[i + 1] == playh)
                break;
            if (_appendIDs[i] == 0) {
                _appendIDs[i] = sid;
                _appendIDs[i + 1] = playh;
                break;
            }
        }
    }
    
    if (_render || _regenCount == 0) {
        gs = _core->acquireGraphics(this);
        docs = new mgvector<long>;
        return _core->acquireFrontDocs(*docs);
    }
    return 0;
}

void GiViewAdapter::regen_(bool changed, int sid, long playh, bool loading) {
    if (_core->isStopping() || !_view.window) {
        return;
    }
    
    long doc0 = 0, doc1 = 0, shapes1 = 0, gs = 0;
    int docd = 0;
    mgvector<long>* docs = NULL;
    
    @synchronized(locker()) {
        docd = regenLocked(changed, sid, playh, loading, doc0, doc1, shapes1, gs, docs);
    }
    
    recordShapes(true, doc0, 0);
    recordShapes(false, doc1, shapes1);
    
    if (_render) {
        [_render startRender:docs :gs];
    } else {
        if (docs) {
            GiCoreView::releaseDocs(*docs);
            delete docs;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [_view setNeedsDisplay];
        });
    }
    if ((doc0 || doc1 || docd) && ++_regenCount == 1) {
        onFirstRegen();
    }
}

void GiViewAdapter::regenAppend(int sid, long playh) {
    regen_(true, sid, playh, false);
}

void GiViewAdapter::stopRegen() {
    _core->stopDrawing();
    [_render stopRender];
    _view = nil;
    if (_dynview) {
        [_dynview removeFromSuperview];
        [_dynview RELEASE];
        _dynview = nil;
    }
}

UIView *GiViewAdapter::getDynView(bool autoCreate) {
    if (autoCreate && !_dynview && _view && _view.window) {
        _dynview = [[GiDynDrawView alloc]initView:_view.frame :this];
        _dynview.autoresizingMask = _view.autoresizingMask;
        if (isMainThread()) {
            [_view.superview addSubview:_dynview];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [_view.superview addSubview:_dynview];
            });
        }
    }
    return _dynview;
}

void GiViewAdapter::redraw(bool changed) {
    if (getDynView(true)) {
        if (changed) {
            @synchronized(locker()) {
                _core->submitDynamicShapes(this);
                if (_queues[1] && !_core->isPlaying()) {
                    long shapes = _core->acquireDynamicShapes();
                    recordShapes(false, 0, shapes);
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [_dynview setNeedsDisplay];
        });
    } else {
        [_view performSelector:@selector(redrawForDelay:)
                    withObject:changed ? _view : nil afterDelay:0.2];
    }
}

bool GiViewAdapter::isMainThread() const {
    return dispatch_get_current_queue() == dispatch_get_main_queue();
}

long GiViewAdapter::acquireFrontDoc(long* gs) {
    long doc;
    
    @synchronized(locker()) {
        doc = _core->acquireFrontDoc();
        if (!doc) {
            _core->submitBackDoc(this);
            doc = _core->acquireFrontDoc();
        }
        if (gs) {
            *gs = _core->acquireGraphics(this);
        }
    }
    
    return doc;
}

bool GiViewAdapter::dispatchGesture(GiGestureType type, GiGestureState state, CGPoint pt) {
    @synchronized(locker()) {
        return _core->onGesture(this, type, state, pt.x, pt.y);
    }
}

bool GiViewAdapter::dispatchPan(GiGestureState state, CGPoint pt, bool switchGesture) {
    @synchronized(locker()) {
        return _core->onGesture(this, kGiGesturePan, state, pt.x, pt.y, switchGesture);
    }
}

bool GiViewAdapter::twoFingersMove(UIGestureRecognizer *sender, int state, bool switchGesture) {
    CGPoint pt1, pt2;
    
    if ([sender numberOfTouches] == 2) {
        pt1 = [sender locationOfTouch:0 inView:sender.view];
        pt2 = [sender locationOfTouch:1 inView:sender.view];
    }
    else {
        pt1 = [sender locationInView:sender.view];
        pt2 = pt1;
    }
    
    state = state < 0 ? (int)sender.state : state;
    @synchronized(locker()) {
        return _core->twoFingersMove(this, (GiGestureState)state,
                                     pt1.x, pt1.y, pt2.x, pt2.y, switchGesture);
    }
}

void GiViewAdapter::hideContextActions() {
    if (_buttons) {
        for (UIView *button in _buttons) {
            [button removeFromSuperview];
        }
        [_buttons removeAllObjects];
    }
}

bool GiViewAdapter::isContextActionsVisible() {
    return _buttons && [_buttons count] > 0;
}

bool GiViewAdapter::showContextActions(const mgvector<int>& actions,
                                       const mgvector<float>& buttonXY,
                                       float x, float y, float w, float h) {
    int n = actions.count();
    UIView *btnParent = _view;
    
    if (n == 0 || !_actionEnabled) {
        hideContextActions();
        return true;
    }
    
    if (!_buttons) {
        _buttons = [[NSMutableArray alloc]init];
    }
    if ([_buttons count] > 0 && _core->isPressDragging()) {
        return false;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:_view
                                             selector:@selector(hideContextActions) object:nil];
    hideContextActions();
    
    for (int i = 0; i < n; i++) {
        const int action = actions.get(i);
        NSString *caption, *imageName;
        
        if (action > 0 && action < sizeof(CAPTIONS)/sizeof(CAPTIONS[0])) {
            caption = CAPTIONS[action];
            imageName = IMAGENAMES[action];
        }
        else if (action - EXTRA_ACTION_BEGIN >= 0
                 && action - EXTRA_ACTION_BEGIN < getExtraImageCount()) {
            caption = @"?";
            imageName = EXTIMAGENAMES[action - EXTRA_ACTION_BEGIN];
        }
        else {
            continue;
        }
        
        UIButtonAutoHide *btn = [[UIButtonAutoHide alloc]initWithFrame:CGRectNull];
        
        btn.delegate = _view;
        btn.tag = action;
        btn.showsTouchWhenHighlighted = YES;
        setContextButton(btn, caption, imageName);
        btn.center = CGPointMake(buttonXY.get(2 * i), buttonXY.get(2 * i + 1));
        
        [btn addTarget:_view action:@selector(onContextAction:) forControlEvents:UIControlEventTouchUpInside];
        btn.frame = [btnParent convertRect:btn.frame fromView:_view];
        [btnParent addSubview:btn];
        [_buttons addObject:btn];
        [btn RELEASE];
    }
    [_view performSelector:@selector(onContextActionsDisplay:) withObject:_buttons];
    
    return [_buttons count] > 0;
}

void GiViewAdapter::setContextButton(UIButton *btn, NSString *caption, NSString *imageName) {
    UIImage *image = nil;
    
    if (imageName) {
        if (!_buttonImages) {
            _buttonImages = [[NSMutableDictionary alloc]init];
        }
        imageName = [@"TouchVG.bundle/" stringByAppendingString:imageName];
        image = [_buttonImages objectForKey:imageName];
        if (!image) {
            image = [UIImage imageNamed:imageName];
            if (image) {
                [_buttonImages setObject:image forKey:imageName];
            }
        }
    }
    if (image) {
        [btn setImage:image forState: UIControlStateNormal];
        [btn setTitle:nil forState: UIControlStateNormal];
        btn.backgroundColor = [UIColor clearColor];
        btn.frame = CGRectMake(0, 0, 32, 32);
    }
    else if (caption) {
        [btn setTitle:caption forState: UIControlStateNormal];
        [btn setTitle:caption forState: UIControlStateHighlighted];
        [btn setTitleColor:[UIColor blackColor] forState: UIControlStateHighlighted];
        btn.backgroundColor = [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.8];
        btn.frame = CGRectMake(0, 0, 60, 36);
    }
}

void GiViewAdapter::commandChanged() {
    for (size_t i = 0; i < delegates.size() && respondsTo.didCommandChanged; i++) {
        if ([delegates[i] respondsToSelector:@selector(onCommandChanged:)]) {
            [delegates[i] onCommandChanged:_view];
        }
    }
    if ([_view respondsToSelector:@selector(onCommandChanged:)]) {
        [_view performSelector:@selector(onCommandChanged:) withObject:_view];
    }
}

void GiViewAdapter::selectionChanged() {
    if (respondsTo.didSelectionChanged || [_view respondsToSelector:@selector(onSelectionChanged:)]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            for (size_t i = 0; i < delegates.size() && respondsTo.didSelectionChanged; i++) {
                if ([delegates[i] respondsToSelector:@selector(onSelectionChanged:)]) {
                    [delegates[i] onSelectionChanged:_view];
                }
            }
            if ([_view respondsToSelector:@selector(onSelectionChanged:)]) {
                [_view performSelector:@selector(onSelectionChanged:) withObject:_view];
            }
        });
    }
}

void GiViewAdapter::contentChanged() {
    if (respondsTo.didContentChanged || [_view respondsToSelector:@selector(onContentChanged:)]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            for (size_t i = 0; i < delegates.size() && respondsTo.didContentChanged; i++) {
                if ([delegates[i] respondsToSelector:@selector(onContentChanged:)]) {
                    [delegates[i] onContentChanged:_view];
                }
            }
            if ([_view respondsToSelector:@selector(onContentChanged:)]) {
                [_view performSelector:@selector(onContentChanged:) withObject:_view];
            }
        });
    }
}

void GiViewAdapter::dynamicChanged() {
    if (respondsTo.didDynamicChanged || [_view respondsToSelector:@selector(onDynamicChanged:)]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            for (size_t i = 0; i < delegates.size() && respondsTo.didDynamicChanged; i++) {
                if ([delegates[i] respondsToSelector:@selector(onDynamicChanged:)]) {
                    [delegates[i] onDynamicChanged:_view];
                }
            }
            if ([_view respondsToSelector:@selector(onDynamicChanged:)]) {
                [_view performSelector:@selector(onDynamicChanged:) withObject:_view];
            }
        });
    }
}

void GiViewAdapter::shapeDeleted(int sid)
{
    for (size_t i = 0; i < delegates.size() && respondsTo.didShapeDeleted; i++) {
        if ([delegates[i] respondsToSelector:@selector(onShapeDeleted:)]) {
            [delegates[i] onShapeDeleted:_view];
        }
    }
    if ([_view respondsToSelector:@selector(onShapeDeleted:)]) {
        [_view performSelector:@selector(onShapeDeleted:) withObject:_view];
    }
}

void GiViewAdapter::onFirstRegen()
{
    for (size_t i = 0; i < delegates.size(); i++) {
        if ([delegates[i] respondsToSelector:@selector(onFirstRegen:)]) {
            [delegates[i] onFirstRegen:_view];
        }
    }
    if ([_view respondsToSelector:@selector(onFirstRegen:)]) {
        [_view performSelector:@selector(onFirstRegen:) withObject:_view];
    }
}

void GiViewAdapter::onDynDrawEnded()
{
    for (size_t i = 0; i < delegates.size() && respondsTo.didDynDrawEnded; i++) {
        if ([delegates[i] respondsToSelector:@selector(onDynDrawEnded:)]) {
            [delegates[i] onDynDrawEnded:_view];
        }
    }
    if ([_view respondsToSelector:@selector(onDynDrawEnded:)]) {
        [_view performSelector:@selector(onDynDrawEnded:) withObject:_view];
    }
}

bool GiViewAdapter::hasShapesRecorded()
{
    return respondsTo.didShapesRecorded || [_view respondsToSelector:@selector(onShapesRecorded:)];
}

void GiViewAdapter::onShapesRecorded(NSDictionary *info)
{
    for (size_t i = 0; i < delegates.size() && respondsTo.didShapesRecorded; i++) {
        if ([delegates[i] respondsToSelector:@selector(onShapesRecorded:)]) {
            [delegates[i] onShapesRecorded:info];
        }
    }
    if ([_view respondsToSelector:@selector(onShapesRecorded:)]) {
        [_view performSelector:@selector(onShapesRecorded:) withObject:info];
    }
}

#include <mach/mach_time.h>

static int machToMs(uint64_t start)
{
    uint64_t elapsedTime = mach_absolute_time() - start;
    static double ticksToNanoseconds = -1.0;
    
    if (ticksToNanoseconds < 0) {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        ticksToNanoseconds = (double)timebase.numer / timebase.denom * 1e-6;
    }
    
    return (int)(elapsedTime * ticksToNanoseconds);
}

int getTickCount()
{
    static uint64_t start = mach_absolute_time();
    return machToMs(start);
}
