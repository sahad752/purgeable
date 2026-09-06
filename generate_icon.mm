#import <Cocoa/Cocoa.h>

static NSImage *TintedImage(NSImage *image, NSColor *color) {
    NSImage *newImage = [image copy];
    [newImage lockFocus];
    [color set];
    NSRect imageRect = {NSZeroPoint, [newImage size]};
    NSRectFillUsingOperation(imageRect, NSCompositingOperationSourceAtop);
    [newImage unlockFocus];
    return newImage;
}

int main() {
    @autoreleasepool {
        CGFloat dim = 1024;
        NSSize size = NSMakeSize(dim, dim);
        NSImage *img = [[NSImage alloc] initWithSize:size];
        [img lockFocus];

        NSRect rect = NSMakeRect(0, 0, dim, dim);
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:220 yRadius:220];
        NSGradient *grad = [[NSGradient alloc]
            initWithStartingColor:[NSColor colorWithCalibratedRed:0.30 green:0.62 blue:0.98 alpha:1.0]
                       endingColor:[NSColor colorWithCalibratedRed:0.10 green:0.32 blue:0.80 alpha:1.0]];
        [grad drawInBezierPath:bg angle:-90];

        NSImage *symbol = [NSImage imageWithSystemSymbolName:@"trash.fill" accessibilityDescription:nil];
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:520 weight:NSFontWeightMedium];
        symbol = [symbol imageWithSymbolConfiguration:cfg];
        [symbol setTemplate:YES];
        NSImage *white = TintedImage(symbol, [NSColor whiteColor]);

        NSSize symSize = white.size;
        NSRect symRect = NSMakeRect((dim - symSize.width) / 2.0,
                                     (dim - symSize.height) / 2.0 - 10,
                                     symSize.width, symSize.height);
        [white drawInRect:symRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];

        [img unlockFocus];

        CGImageRef cgImg = [img CGImageForProposedRect:NULL context:nil hints:nil];
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImg];
        NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [pngData writeToFile:@"icon_1024.png" atomically:YES];
        NSLog(@"wrote icon_1024.png");
    }
    return 0;
}
