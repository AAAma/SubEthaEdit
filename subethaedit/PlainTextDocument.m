//
//  PlainTextDocument.m
//  SubEthaEdit
//
//  Created by Martin Ott on Tue Feb 24 2004.
//  Copyright (c) 2004 TheCodingMonkeys. All rights reserved.
//

#import <Carbon/Carbon.h>

#import "TCMMillionMonkeys/TCMMillionMonkeys.h"
#import "PlainTextEditor.h"
#import "DocumentController.h"
#import "PlainTextDocument.h"
#import "PlainTextWindowController.h"
#import "WebPreviewWindowController.h"

#import "DocumentModeManager.h"
#import "DocumentMode.h"
#import "SyntaxHighlighter.h"
#import "SymbolTableEntry.h"

#import "TextStorage.h"
#import "EncodingManager.h"
#import "TextOperation.h"
#import "SelectionOperation.h"
#import "ODBEditorSuite.h"
#import "GeneralPreferences.h"


#pragma options align=mac68k
struct SelectionRange
{
    short unused1; // 0 (not used)
    short lineNum; // line to select (<0 to specify range)
    long startRange; // start of selection range (if line < 0)
    long endRange; // end of selection range (if line < 0)
    long unused2; // 0 (not used)
    long theDate; // modification date/time
};
#pragma options align=reset


enum {
    UnknownStringEncoding = NoStringEncoding,
    SmallestCustomStringEncoding = 0xFFFFFFF0
};

@interface NSMenuItem (Sorting)
- (NSComparisonResult)compareAlphabetically:(NSMenuItem *)aNotherMenuItem;
@end

@implementation NSMenuItem (Sorting)
- (NSComparisonResult)compareAlphabetically:(NSMenuItem *)aMenuItem {
    return [[self title] caseInsensitiveCompare:[aMenuItem title]];
}
@end

#pragma mark -

static NSString * const PlainTextDocumentSyntaxColorizeNotification = 
                      @"PlainTextDocumentSyntaxColorizeNotification";
NSString * const PlainTextDocumentRefreshWebPreviewNotification = 
               @"PlainTextDocumentRefreshWebPreviewNotification";
NSString * const PlainTextDocumentDidChangeSymbolsNotification =
               @"PlainTextDocumentDidChangeSymbolsNotification";
NSString * const PlainTextDocumentDidChangeEditStatusNotification =
               @"PlainTextDocumentDidChangeEditStatusNotification";
NSString * const PlainTextDocumentParticipantsDidChangeNotification =
               @"PlainTextDocumentParticipantsDidChangeNotification";
NSString * const PlainTextDocumentUserDidChangeSelectionNotification =
               @"PlainTextDocumentUserDidChangeSelectionNotification";
NSString * const PlainTextDocumentDidChangeDisplayNameNotification = 
               @"PlainTextDocumentDidChangeDisplayNameNotification";
NSString * const PlainTextDocumentDefaultParagraphStyleDidChangeNotification = 
               @"PlainTextDocumentDefaultParagraphStyleDidChangeNotification";
NSString * const WrittenByUserIDAttributeName = @"WrittenByUserID";
NSString * const ChangedByUserIDAttributeName = @"ChangedByUserID";

@interface PlainTextDocument (PlainTextDocumentPrivateAdditions) 
- (void)TCM_invalidateDefaultParagraphStyle;
- (void)TCM_styleFonts;
- (void)TCM_initHelper;
- (void)TCM_sendPlainTextDocumentDidChangeDisplayNameNotification;
- (void)TCM_sendPlainTextDocumentDidChangeEditStatusNotification;
- (void)TCM_sendODBCloseEvent;
- (void)TCM_sendODBModifiedEvent;
- (BOOL)TCM_validateDocument;
@end

#pragma mark -

static NSDictionary *plainSymbolAttributes=nil, *italicSymbolAttributes=nil, *boldSymbolAttributes=nil, *boldItalicSymbolAttributes=nil;



@implementation PlainTextDocument

+ (void)initialize {
    NSFontManager *fontManager=[NSFontManager sharedFontManager];
    NSMutableDictionary *attributes=[NSMutableDictionary new];
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new];
    [style setLineBreakMode:NSLineBreakByTruncatingTail];
    [attributes setObject:style forKey:NSParagraphStyleAttributeName];
    NSFont *font=[NSFont menuFontOfSize:[NSFont systemFontSizeForControlSize:NSSmallControlSize]];
    NSFont *boldFont      =[fontManager convertFont:font toHaveTrait:NSBoldFontMask];
    NSFont *italicFont    =[fontManager convertFont:font toHaveTrait:NSItalicFontMask];
    NSFont *boldItalicFont=[fontManager convertFont:boldFont toHaveTrait:NSItalicFontMask];
    [attributes setObject:font forKey:NSFontAttributeName];
    plainSymbolAttributes=[attributes copy];

    [attributes setObject:boldFont forKey:NSFontAttributeName];
    boldSymbolAttributes=[attributes copy];

    [attributes setObject:italicFont forKey:NSFontAttributeName];
    if ([italicFont isEqualTo:font]) {
        [attributes setObject:[NSNumber numberWithFloat:.2] forKey:NSObliquenessAttributeName];
    }
    italicSymbolAttributes=[attributes copy];

    [attributes setObject:boldItalicFont forKey:NSFontAttributeName];
    boldItalicSymbolAttributes=[attributes copy];
    
    [attributes release];
    [style release];
}

- (void)TCM_sendPlainTextDocumentDidChangeDisplayNameNotification {
    [[NSNotificationQueue defaultQueue] 
    enqueueNotification:[NSNotification notificationWithName:PlainTextDocumentDidChangeDisplayNameNotification object:self]
           postingStyle:NSPostWhenIdle 
           coalesceMask:NSNotificationCoalescingOnName | NSNotificationCoalescingOnSender 
               forModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
}

- (void)TCM_sendPlainTextDocumentDidChangeEditStatusNotification {
    [[NSNotificationQueue defaultQueue] 
    enqueueNotification:[NSNotification notificationWithName:PlainTextDocumentDidChangeEditStatusNotification object:self]
           postingStyle:NSPostWhenIdle 
           coalesceMask:NSNotificationCoalescingOnName | NSNotificationCoalescingOnSender 
               forModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
}

- (void)TCM_sendPlainTextDocumentParticipantsDidChangeNotification {
    [[NSNotificationQueue defaultQueue] 
    enqueueNotification:[NSNotification notificationWithName:PlainTextDocumentParticipantsDidChangeNotification object:self]
           postingStyle:NSPostWhenIdle 
           coalesceMask:NSNotificationCoalescingOnName | NSNotificationCoalescingOnSender 
               forModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
}


- (void)TCM_styleFonts {
    [I_fonts.boldFont autorelease];
    [I_fonts.italicFont autorelease];
    [I_fonts.boldItalicFont autorelease];
    NSFontManager *manager=[NSFontManager sharedFontManager];
    I_fonts.boldFont       = [[manager convertFont:I_fonts.plainFont toHaveTrait:NSBoldFontMask] retain];
    I_fonts.italicFont     = [[manager convertFont:I_fonts.plainFont toHaveTrait:NSItalicFontMask] retain];
    I_fonts.boldItalicFont = [[manager convertFont:I_fonts.boldFont  toHaveTrait:NSItalicFontMask] retain];
}

- (void)TCM_initHelper {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(TCM_webPreviewRefreshNotification:)
        name:PlainTextDocumentRefreshWebPreviewNotification object:self];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(performHighlightSyntax)
        name:PlainTextDocumentSyntaxColorizeNotification object:self];
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:NSApp];
    
    // maybe put this into DocumentMode Setting
    NSString *bracketString=@"{[()]}";
    I_bracketMatching.numberOfBrackets=3;
    I_bracketMatching.openingBracketsArray=
        (unichar *)malloc(sizeof(unichar)*I_bracketMatching.numberOfBrackets);
    I_bracketMatching.closingBracketsArray=
        (unichar *)malloc(sizeof(unichar)*I_bracketMatching.numberOfBrackets);
    int i;
    for (i=0;i<I_bracketMatching.numberOfBrackets;i++) {
        I_bracketMatching.openingBracketsArray[i]=[bracketString characterAtIndex:i];
        I_bracketMatching.closingBracketsArray[i]=[bracketString characterAtIndex:(I_bracketMatching.numberOfBrackets*2-1)-i];
    }
    I_flags.showMatchingBrackets=YES;
    I_bracketMatching.matchingBracketPosition=NSNotFound;
    [self setShowsTopStatusBar:YES];
    [self setShowsBottomStatusBar:YES];
    [self setKeepDocumentVersion:NO];
    [self setEditAnyway:NO];
    [self setIsFileWritable:YES];
}

- (void)TCM_sendODBCloseEvent {
    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"preparing ODB close event");
    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"ODBParameters: %@", [[self ODBParameters] description]);
    
    if ([self ODBParameters] == nil || [[self ODBParameters] count] == 0)
        return;
        
    NSString *name = [self fileName];
    if (name == nil || [name length] == 0)
        return;
        
    OSErr err;
    NSURL *fileURL = [NSURL fileURLWithPath:name];
    FSRef fileRef;
    CFURLGetFSRef((CFURLRef)fileURL, &fileRef);
    FSSpec fsSpec;
    err = FSGetCatalogInfo(&fileRef, kFSCatInfoNone, NULL, NULL, &fsSpec, NULL);
    if (err == noErr) {
        NSData *signatureData = [[self ODBParameters] objectForKey:@"keyFileSender"];
        if (signatureData != nil) {
            NSAppleEventDescriptor *addressDescriptor = [NSAppleEventDescriptor descriptorWithDescriptorType:typeApplSignature bytes:[signatureData bytes] length:[signatureData length]];
            if (addressDescriptor != nil) {
                NSAppleEventDescriptor *appleEvent = [NSAppleEventDescriptor appleEventWithEventClass:kODBEditorSuite eventID:kAEClosedFile targetDescriptor:addressDescriptor returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
                NSAppleEventDescriptor *aliasDescriptor = [NSAppleEventDescriptor descriptorWithDescriptorType:typeFSS bytes:&fsSpec length:sizeof(fsSpec)];
                [appleEvent setParamDescriptor:aliasDescriptor forKeyword:keyDirectObject];
                NSAppleEventDescriptor *tokenDesc = [[self ODBParameters] objectForKey:@"keyFileSenderToken"];
                if (tokenDesc != nil) {
                    [appleEvent setParamDescriptor:tokenDesc forKeyword:keySenderToken];
                }
                if (appleEvent != nil) {
                    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Sending apple event");
                    AppleEvent reply;
                    err = AESend([appleEvent aeDesc], &reply, kAENoReply, kAEHighPriority, kAEDefaultTimeout, NULL, NULL);
                }
            }
        }
    }
}

- (void)TCM_sendODBModifiedEvent {
    OSErr err;
    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"preparing ODB modified event");
    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"ODBParameters: %@", [[self ODBParameters] description]);
    if ([self ODBParameters] == nil || [[self ODBParameters] count] == 0)
        return;
    
    NSString *fileName = [self fileName];    
    if (fileName == nil || [fileName length] == 0)
        return;
    
    
    NSURL *fileURL = [NSURL fileURLWithPath:fileName];
    FSRef fileRef;
    CFURLGetFSRef((CFURLRef)fileURL, &fileRef);
    FSSpec fsSpec;
    err = FSGetCatalogInfo(&fileRef, kFSCatInfoNone, NULL, NULL, &fsSpec, NULL);
    NSAppleEventDescriptor *directObjectDesc = nil;
    if (err == noErr) {
        directObjectDesc = [NSAppleEventDescriptor descriptorWithDescriptorType:typeFSS bytes:&fsSpec length:sizeof(fsSpec)];
    } else {
        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Failed to create fsspec");
        return;
    }
            
    if (directObjectDesc != nil) {
        NSData *signatureData = [[self ODBParameters] objectForKey:@"keyFileSender"];
        if (signatureData != nil) {
            NSAppleEventDescriptor *addressDescriptor = [NSAppleEventDescriptor descriptorWithDescriptorType:typeApplSignature bytes:[signatureData bytes] length:[signatureData length]];
            if (addressDescriptor != nil) {
                NSAppleEventDescriptor *appleEvent = [NSAppleEventDescriptor appleEventWithEventClass:kODBEditorSuite eventID:kAEModifiedFile targetDescriptor:addressDescriptor returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
                [appleEvent setParamDescriptor:directObjectDesc forKeyword:keyDirectObject];
                NSAppleEventDescriptor *tokenDesc = [[self ODBParameters] objectForKey:@"keyFileSenderToken"];
                if (tokenDesc != nil) {
                    [appleEvent setParamDescriptor:tokenDesc forKeyword:keySenderToken];
                }
                if (appleEvent != nil) {
                    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Sending apple event");
                    AppleEvent reply;
                    err = AESend([appleEvent aeDesc], &reply, kAENoReply, kAEHighPriority, kAEDefaultTimeout, NULL, NULL);
                }
            }
        }
    } else {
        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Unable to generate direct parameter.");
    }
}

- (BOOL)TCM_charIsClosingBracket:(unichar)aPossibleBracket {
    int i;
    for (i=0;i<I_bracketMatching.numberOfBrackets;i++) {
        if (aPossibleBracket==I_bracketMatching.closingBracketsArray[i]) 
            return YES;
    }
    return NO;
}

- (BOOL)TCM_charIsOpeningBracket:(unichar)aPossibleBracket {
    int i;
    for (i=0;i<I_bracketMatching.numberOfBrackets;i++) {
        if (aPossibleBracket==I_bracketMatching.openingBracketsArray[i]) 
            return YES;
    }
    return NO;
}

- (BOOL)TCM_charIsBracket:(unichar)aPossibleBracket {
    return ([self TCM_charIsOpeningBracket:aPossibleBracket] ||
            [self TCM_charIsClosingBracket:aPossibleBracket]);
}

- (unichar)TCM_matchingBracketForChar:(unichar)bracket {
    int i;
    for (i=0;i<I_bracketMatching.numberOfBrackets;i++) {
        if (bracket==I_bracketMatching.openingBracketsArray[i]) 
            return I_bracketMatching.closingBracketsArray[i];
        if (bracket==I_bracketMatching.closingBracketsArray[i]) 
            return I_bracketMatching.openingBracketsArray[i]; 
    }
    return (unichar)0;
}


- (void)invalidateLayoutForRange:(NSRange)aRange {
    if (aRange.length==0) {
        if (aRange.location>0) {
            aRange.location-=1;
            aRange.length=1;
        } else {
            if ([[self textStorage] length]>0) {
                aRange.length=1;
            }
        }
    }

    NSEnumerator *plainTextEditors=[[self plainTextEditors] objectEnumerator];
    PlainTextEditor *editor=nil;
    while ((editor=[plainTextEditors nextObject])) {
        [[[editor textView] layoutManager] 
            invalidateLayoutForCharacterRange:aRange 
            isSoft:NO actualCharacterRange:NULL];
    }
}

- (void)updateSymbolTable {

    DocumentMode *mode=[self documentMode];
    [I_symbolArray release];
    I_symbolArray=nil;
    if ([mode hasSymbols]) {
        I_symbolArray = [[mode symbolArrayForTextStorage:[self textStorage]] copy];
    
        [I_symbolPopUpMenu release];
        I_symbolPopUpMenu = [NSMenu new];
        [I_symbolPopUpMenuSorted release];
        I_symbolPopUpMenuSorted = [NSMenu new];
        
        NSEnumerator *symbolTableEntries=[I_symbolArray objectEnumerator];
        NSMenuItem *prototypeMenuItem=[[NSMenuItem alloc] initWithTitle:@"" 
                                                                 action:@selector(chooseGotoSymbolMenuItem:) 
                                                          keyEquivalent:@""];
        [prototypeMenuItem setTarget:nil];
        NSMutableArray *itemsToSort=[NSMutableArray array];
    
        SymbolTableEntry *entry;
        int i=0;
        NSMenuItem *menuItem;
        while ((entry=[symbolTableEntries nextObject])) {
            if ([entry isSeparator]) {
                [I_symbolPopUpMenu addItem:[NSMenuItem separatorItem]];
            } else {
                menuItem=[prototypeMenuItem copy];
                [menuItem setTag:i];
                [menuItem setImage:[entry image]];
                int fontTraitMask=[entry fontTraitMask];
                NSDictionary *attributes=plainSymbolAttributes;
                if (fontTraitMask) {
                    switch (fontTraitMask) {
                        case (NSBoldFontMask | NSItalicFontMask):
                            attributes=boldItalicSymbolAttributes;
                            break;
                        case NSItalicFontMask :
                            attributes=italicSymbolAttributes;
                            break;
                        case NSBoldFontMask :
                            attributes=boldSymbolAttributes;
                            break;
                    }
                    [menuItem setAttributedTitle:
                        [[[NSAttributedString alloc] initWithString:[entry name] attributes:attributes] autorelease]];
                }
                [menuItem setTitle:[entry name]];
                [menuItem setIndentationLevel:[entry indentationLevel]];
                [I_symbolPopUpMenu addItem:menuItem];
                [itemsToSort addObject:[[menuItem copy] autorelease]];
                [menuItem release];
            }
            i++;
        }
        [prototypeMenuItem release];
        
        [itemsToSort sortUsingSelector:@selector(compareAlphabetically:)];
        NSEnumerator *menuItems=[itemsToSort objectEnumerator];
        while ((menuItem=[menuItems nextObject])) {
            [I_symbolPopUpMenuSorted addItem:menuItem];
        }
        
    } else {
        I_symbolArray=[NSArray new];
    }
    [[NSNotificationCenter defaultCenter] 
        postNotificationName:PlainTextDocumentDidChangeSymbolsNotification 
        object:self];
}

#define SYMBOLUPDATEINTERVAL 2.5

- (void)triggerUpdateSymbolTableTimer {
    if ([[self documentMode] hasSymbols]) {
        if ([I_symbolUpdateTimer isValid]) {
            [I_symbolUpdateTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:SYMBOLUPDATEINTERVAL]];
        } else {
            [I_symbolUpdateTimer release];
            I_symbolUpdateTimer=[[NSTimer timerWithTimeInterval:SYMBOLUPDATEINTERVAL 
                                                    target:self 
                                                  selector:@selector(symbolTimerAction:)
                                                  userInfo:nil repeats:NO] retain];
            [[NSRunLoop currentRunLoop] addTimer:I_symbolUpdateTimer forMode:NSDefaultRunLoopMode]; //(NSString *)kCFRunLoopCommonModes];
        }
    }
}

- (void)symbolTimerAction:(NSTimer *)aTimer {
    [self updateSymbolTable];
}


- (NSMenu *)symbolPopUpMenuForView:(NSTextView *)aTextView sorted:(BOOL)aSorted {
    NSMenu *menu=aSorted?I_symbolPopUpMenuSorted:I_symbolPopUpMenu;
    NSEnumerator *menuItems=[[menu itemArray] objectEnumerator];    
    NSMenuItem *item;

    static NSMenu *emptyMenu=nil;
    if (!emptyMenu) {
        emptyMenu = [NSMenu new];
        [emptyMenu addItem:[[[NSMenuItem alloc] 
                                initWithTitle:NSLocalizedString(@"<No selected symbol>", 
                                                                @"Entry for Symbol Pop Up when no Symbol is found") 
                                action:@selector(chooseGotoSymbolMenuItem:) 
                                keyEquivalent:@""] autorelease]];
    }
    if ([[menu itemArray] count]) {
    
        while ((item=[menuItems nextObject])) {
            if (![item isSeparatorItem]) {
                [item setRepresentedObject:aTextView];
            }
        } 
        return menu; 
    } else {
        return emptyMenu;
    }

}

- (int)selectedSymbolForRange:(NSRange)aRange {
//    if (aRange.length==0) aRange.length=1;
    int count=[I_symbolArray count];
    int nearest=-1;
    while (--count>=0) {
        SymbolTableEntry *entry=[I_symbolArray objectAtIndex:count];
        if (![entry isSeparator]) {
            NSRange symbolRange=[entry range];
            if (TouchingRanges(aRange,symbolRange)) {
                return count;
            }
            if (nearest==-1 && aRange.location > NSMaxRange(symbolRange)) {
                nearest=count;
            }
        }
    }
    return nearest;
}


- (IBAction)chooseGotoSymbolMenuItem:(NSMenuItem *)aMenuItem {
    if ([aMenuItem tag]<[I_symbolArray count]) {
        NSRange symbolRange=[[I_symbolArray objectAtIndex:[aMenuItem tag]] jumpRange];
        NSTextView *textView=[aMenuItem representedObject];
        NSRange wholeRange=NSMakeRange(0,[[self textStorage] length]);
        symbolRange=NSIntersectionRange(symbolRange,wholeRange);
        if (symbolRange.location==NSNotFound) {
            symbolRange=NSMakeRange(NSMaxRange(wholeRange)>0?NSMaxRange(wholeRange)-1:0,0);
        }
        [textView setSelectedRange:symbolRange];
        [textView scrollRangeToVisible:symbolRange];   
    } else {
        NSBeep();
    }
}

#define STACKLIMIT 100
#define BUFFERSIZE 500

- (unsigned int)TCM_positionOfMatchingBracketToPosition:(unsigned int)position {
    NSString *aString = [[self textStorage] string];
    unsigned int result=NSNotFound;
    unichar possibleBracket=[aString characterAtIndex:position];
    BOOL forward=YES;
    if ([self TCM_charIsOpeningBracket:possibleBracket]) {
        forward=YES;
    } else if ([self TCM_charIsClosingBracket:possibleBracket]) {
        forward=NO;
    } else {
        return result;
    }
    // extra block to only be initialized when thing was a bracket
    {
        unichar stack[STACKLIMIT];
        int stackPosition=0;
        NSRange searchRange,bufferRange;
        unichar buffer[BUFFERSIZE];
        int i;
        BOOL stop=NO;
        
        stack[stackPosition]=[self TCM_matchingBracketForChar:possibleBracket];
        
        if (forward) {
            searchRange=NSMakeRange(position+1,[aString length]-(position+1));
        } else {
            searchRange=NSMakeRange(0,position);
        }
        while (searchRange.length>0 && !stop) {
            if (searchRange.length<=BUFFERSIZE) {
                bufferRange=searchRange;
            } else {
                if (forward) {
                    bufferRange=NSMakeRange(searchRange.location,BUFFERSIZE);
                } else {
                    bufferRange=NSMakeRange(NSMaxRange(searchRange)-BUFFERSIZE,BUFFERSIZE);
                }
            }
            [aString getCharacters:buffer range:bufferRange];
            // go through the buffer
            if (forward) {
                for (i=0;i<(int)bufferRange.length && !stop;i++) {
                    if ([self TCM_charIsOpeningBracket:buffer[i]]) {
                        if (++stackPosition>=STACKLIMIT) {
                            stop=YES;
                        } else {
                            stack[stackPosition]=[self TCM_matchingBracketForChar:buffer[i]];
                        }
                    } else if ([self TCM_charIsClosingBracket:buffer[i]]) {
                        if (buffer[i]!=stack[stackPosition]) {
                            stop=YES;
                        } else {
                            if (--stackPosition<0) {
                                result=bufferRange.location+i;
                                stop=YES;
                            }
                        }
                    }
                }
            } else { // backward
                for (i=bufferRange.length-1;i>=0 && !stop;i--) {
                    if ([self TCM_charIsClosingBracket:buffer[i]]) {
                        if (++stackPosition>=STACKLIMIT) {
                            stop=YES;
                        } else {
                            stack[stackPosition]=[self TCM_matchingBracketForChar:buffer[i]];
                        }
                    } else if ([self TCM_charIsOpeningBracket:buffer[i]]) {
                        if (buffer[i]!=stack[stackPosition]) {
                            NSBeep(); // do it like project builder :-
                            stop=YES;
                        } else {
                            if (--stackPosition<0) {
                                result=bufferRange.location+i;
                                stop=YES;
                            }
                        }
                    }
                }
            }
            if (forward) {
                searchRange.location+=bufferRange.length;
            }
            searchRange.length-=bufferRange.length;
        }
    }
    return result;
}

- (void)TCM_highlightBracketAtPosition:(unsigned)aPosition inTextView:(NSTextView *)aTextView {
    static NSDictionary *mBracketAttributes=nil;
    if (!mBracketAttributes) mBracketAttributes=[[NSDictionary dictionaryWithObject:[[NSColor redColor] highlightWithLevel:0.3] 
                                                    forKey:NSBackgroundColorAttributeName] retain];
    unsigned int matchingBracketPosition=[self TCM_positionOfMatchingBracketToPosition:aPosition];
    if (matchingBracketPosition!=NSNotFound) {
        NSLayoutManager *layoutManager=[aTextView layoutManager];
        [layoutManager addTemporaryAttributes:mBracketAttributes
                            forCharacterRange:NSMakeRange(matchingBracketPosition,1)];
        // Force layout
        (void)[layoutManager textContainerForGlyphAtIndex:
                [layoutManager glyphRangeForCharacterRange:NSMakeRange(matchingBracketPosition,1)
                                      actualCharacterRange:NULL].location effectiveRange:NULL];
        [aTextView displayIfNeeded];
        [[aTextView window] flushWindow];
        [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
        [layoutManager removeTemporaryAttribute:NSBackgroundColorAttributeName
                              forCharacterRange:NSMakeRange(matchingBracketPosition,1)];
    }

}


- (id)init {
    self = [super init];
    if (self) {
        [self setSession:[[TCMMMSession alloc] initWithDocument:self]];
        [[TCMMMPresenceManager sharedInstance] registerSession:[self session]];
        I_textStorage = [TextStorage new];
        [I_textStorage setDelegate:self];
        [self setLineEnding:LineEndingLF];
        [self setDocumentMode:[[DocumentModeManager sharedInstance] modeForNewDocuments]];
        NSStringEncoding encoding = [[[self documentMode] defaultForKey:DocumentModeEncodingPreferenceKey] unsignedIntValue];
        if (encoding < SmallestCustomStringEncoding) {
            [self setFileEncoding:encoding];
        }
        I_flags.isRemotelyEditingTextStorage=NO;
        [self setShowsChangeMarks:[[NSUserDefaults standardUserDefaults] boolForKey:HighlightChangesAlonePreferenceKey] && [[NSUserDefaults standardUserDefaults] boolForKey:HighlightChangesPreferenceKey]];
        [self TCM_initHelper];
    }
    return self;
}

- (id)initWithSession:(TCMMMSession *)aSession {
    self = [super init];
    if (self) {
        [self setSession:aSession];
        [[TCMMMPresenceManager sharedInstance] registerSession:[self session]];
        I_textStorage = [TextStorage new];
        [I_textStorage setDelegate:self];
        [self setDocumentMode:[[DocumentModeManager sharedInstance] baseMode]];
        I_flags.isRemotelyEditingTextStorage=NO;
        [aSession setDocument:self];
        [self setShowsChangeMarks:[[NSUserDefaults standardUserDefaults] boolForKey:HighlightChangesPreferenceKey]];
        [self TCM_initHelper];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (I_flags.isAnnounced) {
        [[TCMMMPresenceManager sharedInstance] concealSession:[self session]];
    }
    
    [self TCM_sendODBCloseEvent];

    [I_symbolUpdateTimer release];
    [I_webPreviewDelayedRefreshTimer release];
        
    [[TCMMMPresenceManager sharedInstance] unregisterSession:[self session]];
    [I_textStorage setDelegate:nil];
    [I_textStorage release];
    [I_webPreviewWindowController release];
    [I_session release];
    [I_plainTextAttributes release];
    [I_typingAttributes release];
    [I_blockeditAttributes release];
    [I_fonts.plainFont release];
    [I_fonts.boldFont release];
    [I_fonts.italicFont release];
    [I_fonts.boldItalicFont release];
    [I_defaultParagraphStyle release];
    [I_fileAttributes release];
    [I_ODBParameters release];
    [I_lineEndingString release];
    [I_symbolArray release];
    [I_symbolPopUpMenu release];
    [I_symbolPopUpMenuSorted release];
    free(I_bracketMatching.openingBracketsArray);
    free(I_bracketMatching.closingBracketsArray);
    [super dealloc];
}

- (void)setSession:(TCMMMSession *)aSession {
    [I_session autorelease];
    I_session = [aSession retain];
}

- (TCMMMSession *)session {
    return I_session;
}

- (NSTextStorage *)textStorage {
    return I_textStorage;
}

- (DocumentMode *)documentMode {
    return I_documentMode;
}

- (void)setDocumentMode:(DocumentMode *)aDocumentMode {
    [I_documentMode autorelease];
    SyntaxHighlighter *highlighter=[I_documentMode syntaxHighlighter];
    [highlighter cleanUpTextStorage:[self textStorage]];
     I_documentMode = [aDocumentMode retain];
    [self setHighlightsSyntax:[[aDocumentMode defaultForKey:DocumentModeHighlightSyntaxPreferenceKey] boolValue]];

    NSDictionary *fontAttributes=[aDocumentMode defaultForKey:DocumentModeFontAttributesPreferenceKey];
    NSFont *newFont=[NSFont fontWithName:[fontAttributes objectForKey:NSFontNameAttribute] size:[[fontAttributes objectForKey:NSFontSizeAttribute] floatValue]];
    if (!newFont) newFont=[NSFont userFixedPitchFontOfSize:[[fontAttributes objectForKey:NSFontSizeAttribute] floatValue]];

    [self setIndentsNewLines:[[aDocumentMode defaultForKey:DocumentModeIndentNewLinesPreferenceKey] boolValue]];
    [self setUsesTabs:[[aDocumentMode defaultForKey:DocumentModeUseTabsPreferenceKey] boolValue]];
    [self setTabWidth:[[aDocumentMode defaultForKey:DocumentModeTabWidthPreferenceKey] intValue]];
    [self setPlainFont:newFont];
    [I_textStorage addAttributes:[self plainTextAttributes]
                               range:NSMakeRange(0,[I_textStorage length])];
    [self setWrapLines:[[aDocumentMode defaultForKey:DocumentModeWrapLinesPreferenceKey] boolValue]];
    [self setWrapMode: [[aDocumentMode defaultForKey:DocumentModeWrapModePreferenceKey] intValue]];
    [self setShowInvisibleCharacters:[[aDocumentMode defaultForKey:DocumentModeShowInvisibleCharactersPreferenceKey] boolValue]];
    [self setShowsGutter:[[aDocumentMode defaultForKey:DocumentModeShowLineNumbersPreferenceKey] intValue]];
    [self setShowsMatchingBrackets:[[aDocumentMode defaultForKey:DocumentModeShowMatchingBracketsPreferenceKey] boolValue]];
    [self setLineEnding:[[aDocumentMode defaultForKey:DocumentModeLineEndingPreferenceKey] intValue]];
    if (I_flags.highlightSyntax) {
        [self highlightSyntaxInRange:NSMakeRange(0,[[self textStorage] length])];
    }
    [self updateSymbolTable];
    [[self plainTextEditors] makeObjectsPerformSelector:@selector(takeSettingsFromDocument)];
}

- (unsigned int)fileEncoding {
    return [(TextStorage *)[self textStorage] encoding];
}

- (void)setFileEncoding:(unsigned int)anEncoding {
    [(TextStorage *)[self textStorage] setEncoding:anEncoding];
    [self TCM_sendPlainTextDocumentDidChangeEditStatusNotification];
}

- (NSDictionary *)fileAttributes {
    return I_fileAttributes;
}

- (void)setFileAttributes:(NSDictionary *)attributes {
    [I_fileAttributes autorelease];
    I_fileAttributes = [attributes retain];
}

- (NSDictionary *)ODBParameters {
    return I_ODBParameters;
}

- (void)setODBParameters:(NSDictionary *)aDictionary {
    [I_ODBParameters autorelease];
    I_ODBParameters = [aDictionary retain];
}

- (BOOL)isAnnounced {
    return I_flags.isAnnounced;
}

- (void)setIsAnnounced:(BOOL)aFlag {
    if (I_flags.isAnnounced!=aFlag) {
        I_flags.isAnnounced=aFlag;
        if (I_flags.isAnnounced) {
            DEBUGLOG(@"Document", 5, @"announce");
            [[TCMMMPresenceManager sharedInstance] announceSession:[self session]];
            [(PlainTextWindowController *)[[self windowControllers] objectAtIndex:0] openParticipantsDrawer:self];
        } else {
            DEBUGLOG(@"Document", 5, @"conceal");
            [[TCMMMPresenceManager sharedInstance] concealSession:[self session]];
        }
    }
}

- (IBAction)toggleIsAnnounced:(id)aSender {
    [self setIsAnnounced:![self isAnnounced]];
}

- (IBAction)showWebPreview:(id)aSender {
    if (!I_webPreviewWindowController) {
        I_webPreviewWindowController=[[WebPreviewWindowController alloc] initWithPlainTextDocument:self];
    }
    if (![[I_webPreviewWindowController window] isVisible]) {
        [I_webPreviewWindowController showWindow:self];
        [I_webPreviewWindowController refresh:self];
    } else {
        [[I_webPreviewWindowController window] orderFront:self];
    }
}


- (IBAction)refreshWebPreview:(id)aSender {
    if (!I_webPreviewWindowController) {
        [self showWebPreview:self];
    } else {
        [I_webPreviewWindowController refresh:self];
    }
}

#define WEBPREVIEWDELAYEDREFRESHINTERVAL 1.2

- (void)triggerDelayedWebPreviewRefresh {
    if ([[self documentMode] hasSymbols]) {
        if ([I_webPreviewDelayedRefreshTimer isValid]) {
            [I_webPreviewDelayedRefreshTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:WEBPREVIEWDELAYEDREFRESHINTERVAL]];
        } else {
            [I_webPreviewDelayedRefreshTimer release];
            I_webPreviewDelayedRefreshTimer=[[NSTimer timerWithTimeInterval:WEBPREVIEWDELAYEDREFRESHINTERVAL 
                                                    target:self 
                                                  selector:@selector(delayedWebPreviewRefreshAction:)
                                                  userInfo:nil repeats:NO] retain];
            [[NSRunLoop currentRunLoop] addTimer:I_webPreviewDelayedRefreshTimer forMode:NSDefaultRunLoopMode]; //(NSString *)kCFRunLoopCommonModes];
        }
    }
}

- (void)delayedWebPreviewRefreshAction:(NSTimer *)aTimer {
    [self refreshWebPreview:self];
}


- (void)TCM_webPreviewRefreshNotification:(NSNotification *)aNotification {
    if ([I_webPreviewWindowController refreshType] == kWebPreviewRefreshAutomatic) {
        [self refreshWebPreview:self];
    } else if ([I_webPreviewWindowController refreshType] == kWebPreviewRefreshDelayed) {
        [self triggerDelayedWebPreviewRefresh];
    }
}

- (void)TCM_webPreviewOnSaveRefresh {
    if (I_webPreviewWindowController) {
        if ([[I_webPreviewWindowController window] isVisible] &&
            [I_webPreviewWindowController refreshType] == kWebPreviewRefreshOnSave) {
            [I_webPreviewWindowController refreshAndEmptyCache:self];
        }
    }
}


- (IBAction)newView:(id)aSender {
    PlainTextWindowController *controller=[PlainTextWindowController new];
    [self addWindowController:controller];
    [controller showWindow:aSender];
    [controller release];
    [self TCM_sendPlainTextDocumentDidChangeDisplayNameNotification];
}

- (IBAction)clearChangeMarks:(id)aSender {
    NSTextStorage *textStorage=[self textStorage];
    [textStorage removeAttribute:ChangedByUserIDAttributeName range:NSMakeRange(0,[textStorage length])];
}

- (void)selectEncoding:(id)aSender {

    NSStringEncoding encoding = [aSender tag];
    
    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, [NSString localizedNameOfStringEncoding:encoding]);
    
    if ([self fileEncoding] != encoding) {

        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert setMessageText:NSLocalizedString(@"File Encoding", nil)];
        [alert setInformativeText:NSLocalizedString(@"ConvertOrReinterpret", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Convert", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Reinterpret", nil)];
        [alert beginSheetModalForWindow:[self windowForSheet]
                          modalDelegate:self 
                         didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:)
                            contextInfo:[[NSDictionary dictionaryWithObjectsAndKeys:
                                                            @"SelectEncodingAlert", @"Alert",
                                                            [NSNumber numberWithUnsignedInt:encoding], @"Encoding",
                                                            nil] retain]];
    }
}

- (void)makeWindowControllers {
    DEBUGLOG(@"blah",5,@"makeWindowCotrollers");
    [self addWindowController:[[PlainTextWindowController new] autorelease]];
}

- (void)removeWindowController:(NSWindowController *)windowController {
    [super removeWindowController:windowController];
    [self TCM_sendPlainTextDocumentDidChangeDisplayNameNotification];
    if ([[self windowControllers] count]==0) {
//        NSLog(@"Last window closed");
        // terminate syntax coloring
        I_flags.highlightSyntax = NO;
        [I_symbolUpdateTimer invalidate];
        [I_webPreviewDelayedRefreshTimer invalidate];
    }
}

- (void)windowControllerWillLoadNib:(NSWindowController *)aController {
    [super windowControllerWillLoadNib:aController];
    DEBUGLOG(@"blah",5,@"Willload");
    // Add any code here that needs to be executed once the windowController has loaded the document's window.
}


- (void)windowControllerDidLoadNib:(NSWindowController *)aController {
    [super windowControllerDidLoadNib:aController];
    DocumentMode *mode=[self documentMode];
    [(PlainTextWindowController *)aController setSizeByColumns:[[mode defaultForKey:DocumentModeColumnsPreferenceKey] intValue] rows:[[mode defaultForKey:DocumentModeRowsPreferenceKey] intValue]];
}

static CFURLRef CFURLFromAEDescAlias(const AEDesc *theDesc) {
    OSErr err;
    AliasHandle localAlias;
    long length;
    CFURLRef theURLRef;
            /* init result */
    theURLRef = NULL;
            /* get alias */
    length = AEGetDescDataSize(theDesc);
    localAlias = (AliasHandle)NewHandle(length);
    if (localAlias != NULL) {
        err = AEGetDescData(theDesc, *localAlias, length);
        if (err == noErr) {
            FSRef target;
            Boolean wasChanged;
            err = FSResolveAlias(NULL, localAlias, &target, &wasChanged);
            if (err == noErr) {
                theURLRef = CFURLCreateFromFSRef(NULL, &target);
            }
        }
        DisposeHandle((Handle)localAlias);
    }
    return theURLRef;
}

- (void)handleOpenDocumentEvent {
    DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"handleOpenDocumentEvent");
    NSAppleEventDescriptor *eventDesc = [[NSAppleEventManager sharedAppleEventManager] currentAppleEvent];
    if (!([eventDesc eventClass] == kCoreEventClass && [eventDesc eventID] == kAEOpenDocuments)) {
        return;
    }
    
    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"%@", [eventDesc description]);

    // Retrieve ODB parameters
    
    // keyFileSender/typeType
    NSAppleEventDescriptor *fileSenderDesc = [[eventDesc paramDescriptorForKeyword:keyFileSender] coerceToDescriptorType:typeType];

    // keyFileSenderToken/typeWildCard(typeList)
    NSAppleEventDescriptor *senderTokenDesc = nil;
    NSAppleEventDescriptor *senderTokenListDesc = [[eventDesc paramDescriptorForKeyword:keyFileSenderToken] coerceToDescriptorType:typeAEList];
    if (!senderTokenListDesc) {
        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"odb token is probably not a list");
        senderTokenDesc = [[eventDesc paramDescriptorForKeyword:keyFileSenderToken] coerceToDescriptorType:typeWildCard];
    } else {
        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"odb tokens were put in a list");

    }
    
    // look for AEPropData appended by LaunchServices
    NSAppleEventDescriptor *propDataAEDesc = [[eventDesc paramDescriptorForKeyword:keyAEPropData] coerceToDescriptorType:typeWildCard];
    if (propDataAEDesc) {
        if (fileSenderDesc == nil) {
            fileSenderDesc = [[propDataAEDesc paramDescriptorForKeyword:keyFileSender] coerceToDescriptorType:typeType];
        }
        if (senderTokenListDesc == nil && senderTokenDesc == nil) {
            senderTokenDesc = [[propDataAEDesc paramDescriptorForKeyword:keyFileSenderToken] coerceToDescriptorType:typeWildCard];
        }
    }
    
    // coerce the document list into a list of CFURLRefs
    NSAppleEventDescriptor *aliasesDesc = [[eventDesc descriptorForKeyword:keyDirectObject] coerceToDescriptorType:typeAEList];
    int numberOfItems = [aliasesDesc numberOfItems];
    int i;
    for (i = 1; i <= numberOfItems; i++) {
        NSAppleEventDescriptor *aliasDesc = [[aliasesDesc descriptorAtIndex:i] coerceToDescriptorType:typeAlias];
        if (aliasDesc) {
            DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"alias: %@", [aliasDesc description]);
            NSURL *fileURL = (NSURL *)CFURLFromAEDescAlias([aliasDesc aeDesc]);
            NSString *filePath = [[fileURL path] stringByStandardizingPath];
            if ([filePath isEqualToString:[[self fileName] stringByStandardizingPath]]) {
            
                // selection may be included in Xcode event
                NSAppleEventDescriptor *selectionDesc = [[eventDesc paramDescriptorForKeyword:keyAEPosition] coerceToDescriptorType:typeChar];
                if (selectionDesc) {
                    struct SelectionRange *selectionRange = nil;
                    selectionRange = (struct SelectionRange *)[[selectionDesc data] bytes];
                    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"lineNum: %d\nstartRange: %d\nendRange: %d", selectionRange->lineNum, selectionRange->startRange, selectionRange->endRange);
                    if (selectionRange->lineNum < 0) {
                        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"selectRange");
                        [self selectRange:NSMakeRange(selectionRange->startRange, selectionRange->endRange - selectionRange->startRange)];
                    } else {
                        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"gotoLine");
                        [self gotoLine:selectionRange->lineNum + 1 orderFront:NO];
                    }
                }
                
                // save ODB parameters in case of ODB event
                NSMutableDictionary *ODBParameters = [NSMutableDictionary dictionary];
                if (fileSenderDesc) {
                    [ODBParameters setObject:[fileSenderDesc data] forKey:@"keyFileSender"];
                }
                
                
                if (senderTokenListDesc) {
                NSAppleEventDescriptor *tokenDesc = [senderTokenListDesc descriptorAtIndex:i];
                    if (tokenDesc) {
                        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"use item in odb list: %d", i);
                        [ODBParameters setObject:tokenDesc forKey:@"keyFileSenderToken"];
                    } else {
                        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"trying first item in odb token list");
                        tokenDesc = [senderTokenListDesc descriptorAtIndex:1];
                        if (tokenDesc) {
                            [ODBParameters setObject:tokenDesc forKey:@"keyFileSenderToken"];
                        } else {
                            DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"first one in the odb token list didn't work");
                        }
                    }
                } else if (senderTokenDesc) {
                    [ODBParameters setObject:senderTokenDesc forKey:@"keyFileSenderToken"];
                }
                
                DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"retrieved ODB parameters: %@", [ODBParameters description]);
                [self setODBParameters:ODBParameters];
            }
            [fileURL release];
        }
    }
}
 
- (void)runModalSavePanelForSaveOperation:(NSSaveOperationType)saveOperation delegate:(id)delegate didSaveSelector:(SEL)didSaveSelector contextInfo:(void *)contextInfo {
    I_lastSaveOperation = saveOperation;
    [super runModalSavePanelForSaveOperation:saveOperation delegate:delegate didSaveSelector:didSaveSelector contextInfo:contextInfo];
}

- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel {
    if (I_lastSaveOperation == NSSaveToOperation) {
        if (![NSBundle loadNibNamed:@"SavePanelAccessory" owner:self])  {
            NSLog(@"Failed to load SavePanelAccessory.nib");
            return nil;
        }

        NSArray *encodings = [[EncodingManager sharedInstance] enabledEncodings];
        NSMutableArray *lossyEncodings = [NSMutableArray array];
        unsigned int i;
        for (i = 0; i < [encodings count]; i++) {
            if (![[I_textStorage string] canBeConvertedToEncoding:[[encodings objectAtIndex:i] unsignedIntValue]]) {
                [lossyEncodings addObject:[encodings objectAtIndex:i]];
            }
        }
        [[EncodingManager sharedInstance] registerEncoding:[self fileEncoding]];
        [O_encodingPopUpButton setEncoding:[self fileEncoding] defaultEntry:NO modeEntry:NO lossyEncodings:lossyEncodings];
        [savePanel setAccessoryView:O_savePanelAccessoryView];
    }
    
    return [super prepareSavePanel:savePanel];
}

- (void)saveDocumentWithDelegate:(id)delegate didSaveSelector:(SEL)didSaveSelector contextInfo:(void *)contextInfo {
    if ([self TCM_validateDocument]) {
        [super saveDocumentWithDelegate:delegate didSaveSelector:didSaveSelector contextInfo:contextInfo];
    }
}

- (void)saveToFile:(NSString *)fileName saveOperation:(NSSaveOperationType)saveOperation delegate:(id)delegate didSaveSelector:(SEL)didSaveSelector contextInfo:(void *)contextInfo {
    if (saveOperation == NSSaveToOperation) {
        I_encodingFromLastRunSaveToOperation = [[O_encodingPopUpButton selectedItem] tag];
    }
    [super saveToFile:fileName saveOperation:saveOperation delegate:delegate didSaveSelector:didSaveSelector contextInfo:contextInfo];
}

- (NSData *)dataRepresentationOfType:(NSString *)aType {

    if ([aType isEqualToString:@"PlainTextType"]) {
        if (I_lastSaveOperation == NSSaveToOperation) {
            DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"Save a copy using encoding: %@", [NSString localizedNameOfStringEncoding:I_encodingFromLastRunSaveToOperation]);
            [[EncodingManager sharedInstance] unregisterEncoding:I_encodingFromLastRunSaveToOperation];
            return [[I_textStorage string] dataUsingEncoding:[self fileEncoding] allowLossyConversion:YES];
        } else {
            DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"Save using encoding: %@", [NSString localizedNameOfStringEncoding:[self fileEncoding]]);
            return [[I_textStorage string] dataUsingEncoding:[self fileEncoding] allowLossyConversion:YES];
        }
    }

    return nil;
}


- (BOOL)readFromFile:(NSString *)fileName ofType:(NSString *)docType {

    DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"readFromFile:%@ ofType:%@", fileName, docType);

    if (![docType isEqualToString:@"PlainTextType"]) {
        return NO;
    }
    
    BOOL isDocumentFromOpenPanel = [(DocumentController *)[NSDocumentController sharedDocumentController] isDocumentFromLastRunOpenPanel:self];
    DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"Document opened via open panel: %@", isDocumentFromOpenPanel ? @"YES" : @"NO");
    
    BOOL isDir, fileExists;
    fileExists = [[NSFileManager defaultManager] fileExistsAtPath:fileName isDirectory:&isDir];
    if (!fileExists || isDir) {
        return NO;
    }
    
    NSTextStorage *textStorage = [self textStorage];

//    int oldLength = [textStorage length];
//    [self setIsNew:NO];

    // Determine mode
    DocumentMode *mode = nil;
    if (isDocumentFromOpenPanel) {
        NSString *identifier = [(DocumentController *)[NSDocumentController sharedDocumentController] modeIdentifierFromLastRunOpenPanel];
        if ([identifier isEqualToString:AUTOMATICMODEIDENTIFIER]) {
            NSString *extension = [fileName pathExtension];
            mode = [[DocumentModeManager sharedInstance] documentModeForExtension:extension];
        } else {
            mode = [[DocumentModeManager sharedInstance] documentModeForIdentifier:identifier];
        }
    }
    
    if (!mode) {
        // get default mode (may be automatic)
        // currently following workaround is used
        mode = [[DocumentModeManager sharedInstance] documentModeForExtension:[fileName pathExtension]];
    }
    
    
    // Determine encoding
    NSStringEncoding encoding;
    if (isDocumentFromOpenPanel) {
        DocumentController *documentController = (DocumentController *)[NSDocumentController sharedDocumentController];
        encoding = [documentController encodingFromLastRunOpenPanel];
        if (encoding == ModeStringEncoding) {
            encoding = [[mode defaultForKey:DocumentModeEncodingPreferenceKey] unsignedIntValue];
        }
    } else {
        encoding = [[mode defaultForKey:DocumentModeEncodingPreferenceKey] unsignedIntValue];
    }
    
    NSDictionary *docAttrs = nil;
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    
    if (encoding < SmallestCustomStringEncoding) {
        DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"Setting \"CharacterEncoding\" option: %@", [NSString localizedNameOfStringEncoding:encoding]);
        [options setObject:[NSNumber numberWithUnsignedInt:encoding] forKey:@"CharacterEncoding"];
    }
    
    //[options setObject:[self plainTextAttributes] forKey:@"DefaultAttributes"];
    
    [[textStorage mutableString] setString:@""]; // Empty the document
    
    NSURL *fileURL = [NSURL fileURLWithPath:[fileName stringByExpandingTildeInPath]];
    
    while (TRUE) {
        BOOL success;
        
        [textStorage beginEditing];
        success = [textStorage readFromURL:fileURL options:options documentAttributes:&docAttrs];
        [textStorage endEditing];
        
        DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"Read successful? %@", success ? @"YES" : @"NO");
        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"documentAttributes: %@", [docAttrs description]);
        
        if (!success) {
            NSNumber *encodingNumber = [options objectForKey:@"CharacterEncoding"];
            if (encodingNumber != nil) {
                NSStringEncoding systemEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringGetSystemEncoding());
                NSStringEncoding triedEncoding = [encodingNumber unsignedIntValue];
                if (triedEncoding == NSUTF8StringEncoding && triedEncoding != systemEncoding) {
                    [[textStorage mutableString] setString:@""]; // Empty the document, and reload
                    [options setObject:[NSNumber numberWithUnsignedInt:systemEncoding] forKey:@"CharacterEncoding"];
                    continue;
                }
            }
            return NO;
        }
        
        if (![[docAttrs objectForKey:@"DocumentType"] isEqualToString:NSPlainTextDocumentType] &&
            ![[options objectForKey:@"DocumentType"] isEqualToString:NSPlainTextDocumentType]) {
            [[textStorage mutableString] setString:@""]; // Empty the document, and reload
            [options setObject:NSPlainTextDocumentType forKey:@"DocumentType"];
        } else {
            break;
        }
    }
    
    [self setFileEncoding:[[docAttrs objectForKey:@"CharacterEncoding"] unsignedIntValue]];
    DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"fileEncoding: %@", [NSString localizedNameOfStringEncoding:[self fileEncoding]]);
    
    [self setKeepDocumentVersion:NO];
    NSDictionary *fattrs = [[NSFileManager defaultManager] fileAttributesAtPath:fileName traverseLink:YES];
    [self setFileAttributes:fattrs];
    BOOL isWritable = [[NSFileManager defaultManager] isWritableFileAtPath:fileName];
    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"isWritable: %@", isWritable ? @"YES" : @"NO");
    [self setIsFileWritable:isWritable];
    
    // guess lineEnding and set instance variable
//    unsigned startIndex = 0;
//    unsigned lineEndIndex = 0;
//    unsigned contentsEndIndex = 0;
//    [[_textStorage string] getLineStart:&startIndex end:&lineEndIndex contentsEnd:&contentsEndIndex forRange:NSMakeRange(0, 0)];
//    
//    unsigned length = lineEndIndex - contentsEndIndex;
//    if (LOGLEVEL(2)) NSLog(@"lineEnding, lineEndIndex: %u, contentsEndIndex: %u, length: %u", lineEndIndex, contentsEndIndex, length);
//    if (length == 1) {
//        unichar character = [[_textStorage string] characterAtIndex:contentsEndIndex];
//        if (character == [@"\n" characterAtIndex:0]) {
//            [self setLineEnding:LineEndingLF];
//        } else if (character == [@"\r" characterAtIndex:0]) {
//            [self setLineEnding:LineEndingCR];
//        }
//    } else if (length == 2) {
//        unichar character1 = [[_textStorage string] characterAtIndex:contentsEndIndex];
//        unichar character2 = [[_textStorage string] characterAtIndex:contentsEndIndex + 1];
//        if ((character1 == [@"\r" characterAtIndex:0]) && (character2 == [@"\n" characterAtIndex:0])) {
//            [self setLineEnding:LineEndingCRLF];
//        }
//    }
//    
//    if (LOGLEVEL(1)) NSLog(@"lineEnding: %u", [self lineEnding]);
    

//    if (_colorizeSyntax) {
//        [self syntaxColorizeInRange:NSMakeRange(0,[_textStorage length])];
//    }

//    if (oldLength > 0) {
//        // inform other about revert
//        [_jupiterUndoManager removeAllActions];
//        [_jupiterObject changeTextInRange:NSMakeRange(0, oldLength)
//                        replacementString:[_textStorage string]]; 
//    }
//    //[self updateMaxYForRadarScroller];

    [I_textStorage addAttributes:[self plainTextAttributes]
                           range:NSMakeRange(0, [I_textStorage length])];

    [self setDocumentMode:mode];
    
    return YES;
}


- (NSDictionary *)fileAttributesToWriteToFile:(NSString *)fullDocumentPath ofType:(NSString *)documentTypeName saveOperation:(NSSaveOperationType)saveOperationType {

    // Preserve HFS Type and Creator code
    if ([self fileName] && [self fileType]) {
        DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"Preserve HFS Type and Creator Code");
        NSMutableDictionary *newAttributes = [NSMutableDictionary dictionaryWithDictionary:[super fileAttributesToWriteToFile:fullDocumentPath ofType:documentTypeName saveOperation:saveOperationType]];
        if ([self fileAttributes] != nil) {
            [newAttributes setObject:[[self fileAttributes] objectForKey:NSFileHFSTypeCode] forKey:NSFileHFSTypeCode];
            [newAttributes setObject:[[self fileAttributes] objectForKey:NSFileHFSCreatorCode] forKey:NSFileHFSCreatorCode];
        } else {
            DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"File is not new, but no fileAttributes are set.");
        }
        return newAttributes;
    }
    
    
    // Otherwise set HFS Type and Creator code with values from bundle
    DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"Save our HFS Type and Creator Code");

    NSDictionary *infoPlist = [[NSBundle mainBundle] infoDictionary];
    NSString *creatorCodeString;
    NSArray *documentTypes;
    NSNumber *typeCode, *creatorCode;
    NSMutableDictionary *newAttributes;
    
    typeCode = creatorCode = nil;
    
    // First, set creatorCode to the HFS creator code for the application,
    // if it exists.
    creatorCodeString = [infoPlist objectForKey:@"CFBundleSignature"];
    if (creatorCodeString) {
        creatorCode = [NSNumber numberWithUnsignedLong:NSHFSTypeCodeFromFileType([NSString stringWithFormat:@"'%@'", creatorCodeString])];
    }
    
    // Then, find the matching Info.plist dictionary entry for this type.
    // Use the first associated HFS type code, if any exist.
    documentTypes = [infoPlist objectForKey:@"CFBundleDocumentTypes"];
    if (documentTypes) {
        int i, count = [documentTypes count];
        
        for(i = 0; i < count; i++) {
            NSString *type = [[documentTypes objectAtIndex:i] objectForKey:@"CFBundleTypeName"];
            if (type && [type isEqualToString:documentTypeName]) {
                NSArray *typeCodeStrings = [[documentTypes objectAtIndex:i] objectForKey:@"CFBundleTypeOSTypes"];
                if (typeCodeStrings) {
                    NSString *firstTypeCodeString = [typeCodeStrings objectAtIndex:0];
                    if (firstTypeCodeString) {
                        typeCode = [NSNumber numberWithUnsignedLong:NSHFSTypeCodeFromFileType([NSString stringWithFormat:@"'%@'",firstTypeCodeString])];
                    }
                }
                break;
            }
        }
    }

    // If neither type nor creator code exist, use the default implementation.
    if (!(typeCode || creatorCode)) {
        return [super fileAttributesToWriteToFile:fullDocumentPath ofType:documentTypeName saveOperation:saveOperationType];
    }
    
    // Otherwise, add the type and/or creator to the dictionary.
    newAttributes = [NSMutableDictionary dictionaryWithDictionary:[super
        fileAttributesToWriteToFile:fullDocumentPath ofType:documentTypeName
        saveOperation:saveOperationType]];
    if (typeCode)
        [newAttributes setObject:typeCode forKey:NSFileHFSTypeCode];
    if (creatorCode)
        [newAttributes setObject:creatorCode forKey:NSFileHFSCreatorCode];
        
    [self setFileAttributes:newAttributes];
    return newAttributes;
}

- (BOOL)writeWithBackupToFile:(NSString *)fullDocumentPath ofType:(NSString *)docType saveOperation:(NSSaveOperationType)saveOperationType {
    DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"writeWithBackupToFile: %@", fullDocumentPath);
    BOOL result = [super writeWithBackupToFile:fullDocumentPath ofType:docType saveOperation:saveOperationType];
    if (result) {
        if (saveOperationType == NSSaveOperation) {
            [self TCM_sendODBModifiedEvent];
            [self setKeepDocumentVersion:NO];
        } else if (saveOperationType == NSSaveAsOperation) {
            if ([fullDocumentPath isEqualToString:[self fileName]]) {
                [self TCM_sendODBModifiedEvent];
            } else {
                [self setODBParameters:nil];
            }
        }
        [self TCM_webPreviewOnSaveRefresh];
    }
    
    if (saveOperationType != NSSaveToOperation) {
        NSDictionary *fattrs = [[NSFileManager defaultManager] fileAttributesAtPath:fullDocumentPath traverseLink:YES];
        [self setFileAttributes:fattrs];
        [self setIsFileWritable:[[NSFileManager defaultManager] isWritableFileAtPath:fullDocumentPath]];
    }
    
    return result;
}

- (BOOL)TCM_validateDocument {
    NSWindow *window = [self windowForSheet];
    if (!window) {
        return YES;
    }
    
    NSString *fileName = [self fileName];
    DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"Validate document: %@", fileName);
    
    NSDictionary *fattrs = [[NSFileManager defaultManager] fileAttributesAtPath:fileName traverseLink:YES];
    if ([[fattrs fileModificationDate] compare:[[self fileAttributes] fileModificationDate]] != NSOrderedSame) {
        DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Document has been changed externally");
        if ([self keepDocumentVersion]) {
            DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Keep document version");
            return YES;
        }
        // FIXME: What to do when we are in collaboration mode and hosting the document?
        if ([self isDocumentEdited]) {
            NSAlert *alert = [[[NSAlert alloc] init] autorelease];
            [alert setAlertStyle:NSWarningAlertStyle];
            [alert setMessageText:NSLocalizedString(@"Warning", nil)];
            [alert setInformativeText:NSLocalizedString(@"Document changed externally", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Keep SubEthaEdit Version", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Revert", nil)];
            [[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
            [alert beginSheetModalForWindow:window
                              modalDelegate:self 
                             didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:)
                                contextInfo:[[NSDictionary dictionaryWithObjectsAndKeys:
                                                                @"DocumentChangedExternallyAlert", @"Alert",
                                                                nil] retain]];
        } else {
            DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Revert document");
            BOOL successful = [self revertToSavedFromFile:[self fileName] ofType:[self fileType]];
            if (successful) {
                [self updateChangeCount:NSChangeCleared];
            }
        }
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validateMenuItem:(NSMenuItem *)anItem {
    SEL selector=[anItem action];
    if (selector==@selector(announce:)) {
        return !I_flags.isAnnounced;
    } else if (selector==@selector(conceal:)) {
        return I_flags.isAnnounced;
    } else if (selector==@selector(toggleSyntaxHighlighting:)) {
        [anItem setState:(I_flags.highlightSyntax?NSOnState:NSOffState)];
        return YES;
    } else if (selector == @selector(chooseLineEndings:)) {
        if ([self lineEnding] == [anItem tag]) {
            [anItem setState:NSOnState];
        } else {
            [anItem setState:NSOffState];
        }
    } else if (selector == @selector(convertLineEndings:)) {
        NSStringEncoding encoding=[self fileEncoding];
        return ([anItem tag]<LineEndingUnicodeLineSeparator ||
                encoding==NSUnicodeStringEncoding ||
                encoding==NSUTF8StringEncoding ||
                encoding==NSNonLossyASCIIStringEncoding);                  
    } else if (selector == @selector(selectEncoding:)) {
        if ([self fileEncoding] == (unsigned int)[anItem tag]) {
            [anItem setState:NSOnState];
        } else {
            [anItem setState:NSOffState];
        }
    } else if (selector == @selector(chooseMode:)) {
        DocumentModeManager *modeManager=[DocumentModeManager sharedInstance];
        NSString *identifier=[modeManager documentModeIdentifierForTag:[anItem tag]];
        if (identifier && [[[self documentMode] documentModeIdentifier] isEqualToString:identifier]) {
            [anItem setState:NSOnState];
        } else {
            [anItem setState:NSOffState];
        }
    } else if (selector == @selector(toggleUsesTabs:)) {
        [anItem setState:(I_flags.usesTabs?NSOnState:NSOffState)];
        return YES;
    } else if (selector == @selector(selectWrapMode:)) {
        [anItem setState:(I_flags.wrapMode==[anItem tag]?NSOnState:NSOffState)];
        return YES;
    } else if (selector == @selector(toggleIndentNewLines:)) {
        [anItem setState:(I_flags.indentNewLines?NSOnState:NSOffState)];
        return YES;
    } else if (selector == @selector(changeTabWidth:)) {
        [anItem setState:(I_tabWidth==[[anItem title]intValue]?NSOnState:NSOffState)];
    } else if (selector == @selector(toggleIsAnnounced:)) {
        [anItem setTitle:[self isAnnounced]?
                         NSLocalizedString(@"Conceal",@"Menu/Toolbar Title for concealing the Document"):
                         NSLocalizedString(@"Announce",@"Menu/Toolbar Title for announcing the Document")];
        return YES;
    }

    return [super validateMenuItem:anItem];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)toolbarItem {
    NSString *itemIdentifier = [toolbarItem itemIdentifier];
    
    if ([itemIdentifier isEqualToString:ToggleAnnouncementToolbarItemIdentifier]) {
        BOOL isAnnounced=[self isAnnounced];
        [toolbarItem setImage:isAnnounced
                              ?[NSImage imageNamed: @"Conceal"]
                              :[NSImage imageNamed: @"Announce"]];
        [toolbarItem setLabel:isAnnounced? 
                         NSLocalizedString(@"Conceal",@"Menu/Toolbar Title for concealing the Document"):
                         NSLocalizedString(@"Announce",@"Menu/Toolbar Title for announcing the Document")];
        return YES;
    }
    
    return YES;
}

- (NSString *)lineEndingString {
    return I_lineEndingString;
}

- (LineEnding)lineEnding {
    return I_lineEnding;
}

// http://developer.apple.com/documentation/Carbon/Conceptual/ATSUI_Concepts/atsui_chap4/chapter_4_section_5.html

- (void)setLineEnding:(LineEnding)newLineEnding {
    static NSString *sUnicodeLSEP=nil;
    static NSString *sUnicodePSEP=nil;
    if (sUnicodeLSEP==nil) {
        unichar seps[2];
        seps[0]=0x2028;
        seps[1]=0x2029;
        sUnicodeLSEP=[[NSString stringWithCharacters:seps length:1] retain];
        sUnicodePSEP=[[NSString stringWithCharacters:seps+1 length:1] retain];
    }

    if (I_lineEnding !=newLineEnding) {
        I_lineEnding = newLineEnding;
        switch(I_lineEnding) {
            case LineEndingLF:
                I_lineEndingString=@"\n";
                break;
            case LineEndingCR:
                I_lineEndingString=@"\r";
                break;
            case LineEndingCRLF:
                I_lineEndingString=@"\r\n";
                break;
            case LineEndingUnicodeLineSeparator:
                I_lineEndingString=sUnicodeLSEP;
                break;
            case LineEndingUnicodeParagraphSeparator:
                I_lineEndingString=sUnicodePSEP;
                break;
            default:
                I_lineEndingString=@"\n";
                break;      
        }
    }
    [self TCM_sendPlainTextDocumentDidChangeEditStatusNotification];
}

- (IBAction)chooseLineEndings:(id)aSender {
    [self setLineEnding:[aSender tag]];
}

- (IBAction)convertLineEndings:(id)aSender {
    [self setLineEnding:[aSender tag]];
    [[[self textStorage] mutableString] convertLineEndingsToLineEndingString:[self lineEndingString]];
    [[self undoManager] removeAllActions]; 
    // undo is not too easy here... however... we could store a complete copy of the document in the undobuffer
}

- (NSRange)rangeOfPrevious:(BOOL)aPrevious symbolForRange:(NSRange)aRange {
    if ([[self documentMode] hasSymbols] && [I_symbolArray count]) {
        int position=[self selectedSymbolForRange:aRange];
        if (aPrevious) {
            if (position==-1) return NSMakeRange(NSNotFound,0);
            NSRange symbolRange=[[I_symbolArray objectAtIndex:position] jumpRange];
            if (DisjointRanges(aRange,symbolRange) && symbolRange.location<aRange.location) { 
                return symbolRange;
            } else {
                while (position-->0) {
                    SymbolTableEntry *entry=[I_symbolArray objectAtIndex:position];
                    if (![entry isSeparator]) {
                        return [entry jumpRange];
                    }
                }
            }
        } else {
            if (position==-1) position=0;
            while (position<[I_symbolArray count]) {
                SymbolTableEntry *entry=[I_symbolArray objectAtIndex:position];
                if (![entry isSeparator]) {
                    NSRange symbolRange=[[I_symbolArray objectAtIndex:position] jumpRange];
                    if (DisjointRanges(aRange,symbolRange) && NSMaxRange(symbolRange)>NSMaxRange(aRange)) { 
                        return symbolRange;
                    } 
                }
                position++;
            }
        }
    }
    return NSMakeRange(NSNotFound,0);
}

- (NSRange)rangeOfPrevious:(BOOL)aPrevious changeForRange:(NSRange)aRange {
    NSRange searchRange;
    TextStorage *textStorage=(TextStorage *)[self textStorage];
    NSString *userID=nil;
    unsigned position;
    NSRange fullRange=NSMakeRange(0,[textStorage length]);
    if (aRange.location>=fullRange.length) {
        if (aRange.location>0) aRange.location-=1;
        else return NSMakeRange(NSNotFound,0);
    }  
    userID=[textStorage attribute:ChangedByUserIDAttributeName atIndex:aRange.location longestEffectiveRange:&searchRange inRange:fullRange];
    userID=nil;
    while (!userID) {
        if (aPrevious) {
            if (searchRange.location==0) {
                return NSMakeRange(NSNotFound,0);
            }
            position=searchRange.location-1;
        } else {
            position=NSMaxRange(searchRange);
            if (position>=fullRange.length) {
                return NSMakeRange(NSNotFound,0);
            }
        }
        userID = [textStorage attribute:ChangedByUserIDAttributeName 
                                atIndex:position 
                  longestEffectiveRange:&searchRange
                                inRange:fullRange];
    }
    
    return searchRange;
}


/*"A font trait mask of 0 returns the plain font, otherwise use NSBoldFontMask, NSItalicFontMask"*/
- (NSFont *)fontWithTrait:(NSFontTraitMask)aFontTrait {
    if ((aFontTrait & NSBoldFontMask) && (aFontTrait & NSItalicFontMask)) {
        return I_fonts.boldItalicFont;
    } else if (aFontTrait & NSItalicFontMask) {
        return I_fonts.italicFont;
    } else if (aFontTrait & NSBoldFontMask) {
        return I_fonts.boldFont;
    } else {
        return I_fonts.plainFont;
    }
}

- (void)setPlainFont:(NSFont *)aFont {
    [I_fonts.plainFont autorelease];
    I_fonts.plainFont = [aFont copy];
    [self TCM_styleFonts];
    [I_plainTextAttributes release];
    I_plainTextAttributes=nil;
    [I_typingAttributes release];
    I_typingAttributes=nil;
    [self TCM_invalidateDefaultParagraphStyle];
}

- (NSDictionary *)typingAttributes {
    if (!I_typingAttributes) {
        NSMutableDictionary *attributes=[[self plainTextAttributes] mutableCopy];
        NSString *myUserID=[TCMMMUserManager myUserID];
        [attributes setObject:myUserID forKey:WrittenByUserIDAttributeName];
        [attributes setObject:myUserID forKey:ChangedByUserIDAttributeName];
        I_typingAttributes=(NSDictionary *)attributes;
    }
    return I_typingAttributes;
}

- (NSDictionary *)plainTextAttributes {
    if (!I_plainTextAttributes) {
//        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSFont *userFont = [NSFont userFixedPitchFontOfSize:0.0];
//        BOOL usesScreenFonts = [[defaults objectForKey:UsesScreenFontsPreferenceKey] boolValue];
        NSFont *displayFont = nil;
        if (NO)
            displayFont = [userFont screenFont];
        if (displayFont == nil)
            displayFont = userFont;
//        NSMutableParagraphStyle *myParagraphStyle = [[NSMutableParagraphStyle new] autorelease];
//        [myParagraphStyle setParagraphStyle:[NSParagraphStyle defaultParagraphStyle]];
//        NSArray *tabStops;
        //float spaceWidth = [userFont widthOfString:@" "];
//        unsigned spacesPerTab=[defaults integerForKey:TabWidthPreferenceKey];
        //float tabWidth = spaceWidth*spacesPerTab;

//        tabStops = tabStopArrayForFontAndTabWidth(displayFont, spacesPerTab);

//        [myParagraphStyle setTabStops:tabStops];
        NSColor *foregroundColor=[NSColor blackColor];

        NSMutableDictionary *attributes=[NSMutableDictionary new];
        [attributes setObject:[self fontWithTrait:0]
                            forKey:NSFontAttributeName];
        [attributes setObject:[NSNumber numberWithInt:0]
                            forKey:NSLigatureAttributeName];
//        [I_plainTextAttributes setObject:myParagraphStyle
//                            forKey:NSParagraphStyleAttributeName];
        [attributes setObject:foregroundColor
                            forKey:NSForegroundColorAttributeName];
        I_plainTextAttributes=attributes;
    }
    return I_plainTextAttributes;

}

/*"This method returns the blockeditTextAttributes that the textview uses. If you make background colors customizeable you want to change these too"*/
- (NSDictionary *)blockeditAttributes {
    if (!I_blockeditAttributes) {
        float backgroundBrightness=1.0;
        if (backgroundBrightness>.5) backgroundBrightness-=.1;
        else backgroundBrightness+=.1;
        NSColor *blockeditColor=[NSColor colorWithCalibratedWhite:backgroundBrightness alpha:1.];
        I_blockeditAttributes=[[NSDictionary dictionaryWithObjectsAndKeys:
                            blockeditColor,NSBackgroundColorAttributeName,
                            BlockeditAttributeValue,BlockeditAttributeName,
                            nil] retain];
    }
    return I_blockeditAttributes;
}


- (NSParagraphStyle *)defaultParagraphStyle {
    if (!I_defaultParagraphStyle) {
        I_defaultParagraphStyle = [[NSMutableParagraphStyle alloc] init];
        [I_defaultParagraphStyle setTabStops:[NSArray array]];
        NSFont *font=[self fontWithTrait:nil];
        float charWidth = [font widthOfString:@" "];
        if (charWidth<=0) {
            charWidth=[font maximumAdvancement].width;
        }
        [I_defaultParagraphStyle setLineBreakMode:I_flags.wrapMode==DocumentModeWrapModeCharacters?NSLineBreakByCharWrapping:NSLineBreakByWordWrapping];
        [I_defaultParagraphStyle setDefaultTabInterval:charWidth*I_tabWidth];
        [I_defaultParagraphStyle addTabStop:[[[NSTextTab alloc] initWithType:NSLeftTabStopType location:charWidth*I_tabWidth] autorelease]];
        [[self textStorage] addAttribute:NSParagraphStyleAttributeName value:I_defaultParagraphStyle range:NSMakeRange(0,[[self textStorage] length])];
    }
    return I_defaultParagraphStyle;
}


- (void)TCM_invalidateDefaultParagraphStyle {
    [I_defaultParagraphStyle autorelease];
    I_defaultParagraphStyle=nil;
    [[NSNotificationQueue defaultQueue] 
        enqueueNotification:[NSNotification notificationWithName:PlainTextDocumentDefaultParagraphStyleDidChangeNotification object:self]
               postingStyle:NSPostWhenIdle 
               coalesceMask:NSNotificationCoalescingOnName | NSNotificationCoalescingOnSender 
                   forModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
}

- (PlainTextWindowController *)topmostWindowController {
    NSEnumerator *orderedWindowEnumerator=[[NSApp orderedWindows] objectEnumerator];
    NSWindow *window;
    PlainTextWindowController *result=nil;
    while ((window=[orderedWindowEnumerator nextObject])) {
        if ([[window windowController] document]==self) {
            result=[window windowController];
            break;
        }
    }
    if (!result) result=[[self windowControllers] objectAtIndex:0];
    return result;
}


- (void)gotoLine:(unsigned)aLine {
    [self gotoLine:aLine orderFront:NO];
}

- (void)gotoLine:(unsigned)aLine orderFront:(BOOL)aFlag {
    PlainTextWindowController *windowController=[self topmostWindowController];
    [windowController gotoLine:aLine];
    if (aFlag) [[windowController window] makeKeyAndOrderFront:self];
}

- (void)selectRange:(NSRange)aRange {
    PlainTextWindowController *windowController=[self topmostWindowController];
    [windowController selectRange:aRange];
    [[windowController window] makeKeyAndOrderFront:self];
}

#pragma mark -
#pragma mark ### Flag Accessors ###
// wrapline setting is only for book keeping - editor scope
- (BOOL)showInvisibleCharacters {
    return I_flags.showInvisibleCharacters;
}

- (void)setShowInvisibleCharacters:(BOOL)aFlag {
    I_flags.showInvisibleCharacters=aFlag;
}


// wrapline setting is only for book keeping - editor scope
- (BOOL)wrapLines {
    return I_flags.wrapLines;
}

- (void)setWrapLines:(BOOL)aFlag {
    if (I_flags.wrapLines!=aFlag) {
        I_flags.wrapLines=aFlag;
        [self TCM_sendPlainTextDocumentDidChangeEditStatusNotification];
    }
}

- (int)wrapMode {
    return I_flags.wrapMode;
}

- (void)setWrapMode:(int)newMode {
    if (I_flags.wrapMode!=newMode) {
        I_flags.wrapMode=newMode;
        [self TCM_invalidateDefaultParagraphStyle];
        [self TCM_sendPlainTextDocumentDidChangeEditStatusNotification];
    }
}

- (void)setUsesTabs:(BOOL)aFlag {
    if (I_flags.usesTabs!=aFlag) {
        I_flags.usesTabs=aFlag;
        [self TCM_sendPlainTextDocumentDidChangeEditStatusNotification];
    }
}

- (BOOL)usesTabs {
    return I_flags.usesTabs;
}

- (int)tabWidth {
    return I_tabWidth;
}

- (void)setTabWidth:(int)aTabWidth {
    I_tabWidth=aTabWidth;
    if (I_tabWidth<1) {
        I_tabWidth=1;
    }
    [self TCM_invalidateDefaultParagraphStyle];
    [self TCM_sendPlainTextDocumentDidChangeEditStatusNotification];
}

- (BOOL)showsGutter {
    return I_flags.showGutter;
}

- (void)setShowsGutter:(BOOL)aFlag {
    I_flags.showGutter=aFlag;
}

- (BOOL)showsMatchingBrackets {
    return I_flags.showMatchingBrackets;
}
- (void)setShowsMatchingBrackets:(BOOL)aFlag {
    I_flags.showMatchingBrackets = aFlag;
}

- (BOOL)showsChangeMarks {
    return I_flags.showsChangeMarks;
}

- (void)setShowsChangeMarks:(BOOL)aFlag {
    I_flags.showsChangeMarks=aFlag;
}

- (BOOL)indentsNewLines {
    return I_flags.indentNewLines;
}
- (void)setIndentsNewLines:(BOOL)aFlag {
    I_flags.indentNewLines=aFlag;
}

- (BOOL)showsTopStatusBar {
    return I_flags.showsTopStatusBar;
}
- (void)setShowsTopStatusBar:(BOOL)aFlag {
    I_flags.showsTopStatusBar=aFlag;
}

- (BOOL)showsBottomStatusBar {
    return I_flags.showsBottomStatusBar;
}
- (void)setShowsBottomStatusBar:(BOOL)aFlag {
    I_flags.showsBottomStatusBar=aFlag;
}

- (BOOL)keepDocumentVersion {
    return I_flags.keepDocumentVersion;
}

- (void)setKeepDocumentVersion:(BOOL)aFlag {
    I_flags.keepDocumentVersion = aFlag;
}

- (BOOL)isFileWritable {
    return I_flags.isFileWritable;
}

- (void)setIsFileWritable:(BOOL)aFlag {
    I_flags.isFileWritable = aFlag;
}

- (BOOL)editAnyway {
    return I_flags.editAnyway;
}

- (void)setEditAnyway:(BOOL)aFlag {
    I_flags.editAnyway = aFlag;
}

#pragma mark -

- (void)alertDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo {
    NSDictionary *alertContext = (NSDictionary *)contextInfo;
    NSString *alertIdentifier = [alertContext objectForKey:@"Alert"];
    DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"alertDidEnd: %@", alertIdentifier);

    if ([alertIdentifier isEqualToString:@"SelectEncodingAlert"]) {
        NSStringEncoding encoding = [[alertContext objectForKey:@"Encoding"] unsignedIntValue];
        if (returnCode == NSAlertFirstButtonReturn) {
            DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Trying to convert file encoding");
            [[alert window] orderOut:self];
            if (![[I_textStorage string] canBeConvertedToEncoding:encoding]) {
                NSAlert *newAlert = [[[NSAlert alloc] init] autorelease];
                [newAlert setAlertStyle:NSWarningAlertStyle];
                [newAlert setMessageText:NSLocalizedString(@"Error", nil)];
                [newAlert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Encoding %@ not applicable", nil), [NSString localizedNameOfStringEncoding:encoding]]];
                [newAlert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
                [newAlert beginSheetModalForWindow:[self windowForSheet]
                                     modalDelegate:nil 
                                    didEndSelector:nil
                                       contextInfo:NULL];            
            } else {
                [self setFileEncoding:encoding];
                [self updateChangeCount:NSChangeDone];
            }
        }

        if (returnCode == NSAlertThirdButtonReturn) {
            DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Trying to reinterpret file encoding");
            [[alert window] orderOut:self];
            NSData *stringData = [[I_textStorage string] dataUsingEncoding:[self fileEncoding]];
            NSString *reinterpretedString = [[NSString alloc] initWithData:stringData encoding:encoding];
            if (!reinterpretedString) {
                NSAlert *newAlert = [[[NSAlert alloc] init] autorelease];
                [newAlert setAlertStyle:NSWarningAlertStyle];
                [newAlert setMessageText:NSLocalizedString(@"Error", nil)];
                [newAlert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Encoding %@ not reinterpretable", nil), [NSString localizedNameOfStringEncoding:encoding]]];
                [newAlert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
                [newAlert beginSheetModalForWindow:[self windowForSheet]
                                     modalDelegate:nil 
                                    didEndSelector:nil
                                       contextInfo:NULL];              
            } else {
                [I_textStorage beginEditing];
                [I_textStorage replaceCharactersInRange:NSMakeRange(0, [I_textStorage length]) withString:reinterpretedString];
                [I_textStorage setAttributes:[self plainTextAttributes] range:NSMakeRange(0, [I_textStorage length])];
                
                if (I_flags.highlightSyntax) {
                    [self highlightSyntaxInRange:NSMakeRange(0, [I_textStorage length])];
                }
        
                [I_textStorage endEditing];
                
                [reinterpretedString release];
                [self setFileEncoding:encoding];
                [self updateChangeCount:NSChangeDone];            
            }
        }
    } else if ([alertIdentifier isEqualToString:@"ShouldPromoteAlert"]) {
        if (returnCode == NSAlertThirdButtonReturn) {
            [self setFileEncoding:NSUnicodeStringEncoding];
            NSTextView *textView = [alertContext objectForKey:@"TextView"];
            [textView insertText:[alertContext objectForKey:@"ReplacementString"]];
        } else if (returnCode == NSAlertSecondButtonReturn) {
            [self setFileEncoding:NSUTF8StringEncoding];
            NSTextView *textView = [alertContext objectForKey:@"TextView"];
            [textView insertText:[alertContext objectForKey:@"ReplacementString"]];
        }
    } else if ([alertIdentifier isEqualToString:@"DocumentChangedExternallyAlert"]) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [self setKeepDocumentVersion:YES];
        } else if (returnCode == NSAlertSecondButtonReturn) {
            DEBUGLOG(@"FileIOLogDomain", DetailedLogLevel, @"Revert document");
            BOOL successful = [self revertToSavedFromFile:[self fileName] ofType:[self fileType]];
            if (successful) {
                [self updateChangeCount:NSChangeCleared];
            }
        }
    } else if ([alertIdentifier isEqualToString:@"EditAnywayAlert"]) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [self setEditAnyway:YES];
            NSTextView *textView = [alertContext objectForKey:@"TextView"];
            [textView insertText:[alertContext objectForKey:@"ReplacementString"]];        
        }
    }
    
    [alertContext autorelease];
}

- (void)applicationDidBecomeActive:(NSNotification *)aNotification {
    DEBUGLOG(@"FileIOLogDomain", SimpleLogLevel, @"applicationDidBecomeActive: %@", [self fileName]);
    if (![self fileName]) {
        return;
    }
    
    (void)[self TCM_validateDocument];
}

#pragma mark -
#pragma mark ### Syntax Highlighting ###

- (IBAction)selectWrapMode:(id)aSender {
    [self setWrapMode:[aSender tag]];
}

- (IBAction)toggleUsesTabs:(id)aSender {
    [self setUsesTabs:![self usesTabs]];
}

- (IBAction)toggleIndentNewLines:(id)aSender {
    I_flags.indentNewLines=!I_flags.indentNewLines;
}

- (IBAction)changeTabWidth:(id)aSender {
    [self setTabWidth:[[aSender title] intValue]];
}

- (IBAction)chooseMode:(id)aSender {
    DocumentModeManager *modeManager=[DocumentModeManager sharedInstance];
    NSString *identifier=[modeManager documentModeIdentifierForTag:[aSender tag]];
    if (identifier) {
        DocumentMode *newMode=[modeManager documentModeForIdentifier:identifier];
        [self setDocumentMode:newMode];
    }
}

- (void)changeFont:(id)aSender {
    NSFont *newFont = [aSender convertFont:I_fonts.plainFont];
    [self setPlainFont:newFont];
        [I_textStorage addAttributes:[self plainTextAttributes]
                               range:NSMakeRange(0,[I_textStorage length])];
    if (I_flags.highlightSyntax) {
        [self highlightSyntaxInRange:NSMakeRange(0,[[self textStorage] length])];
    }

}

- (void)setHighlightsSyntax:(BOOL)aFlag {
    if (I_flags.highlightSyntax != aFlag) {
        I_flags.highlightSyntax = aFlag;
        if (I_flags.highlightSyntax) {
            [self highlightSyntaxInRange:NSMakeRange(0,[I_textStorage length])];
        } else {
            [I_textStorage addAttributes:[self plainTextAttributes]
                                   range:NSMakeRange(0,[I_textStorage length])];
        }
    }
}

- (BOOL)highlightsSyntax {
    return I_flags.highlightSyntax;
}

- (IBAction)toggleSyntaxHighlighting:(id)aSender {
    [self setHighlightsSyntax:![self highlightsSyntax]];
}

- (void)highlightSyntaxInRange:(NSRange)aRange {
    if (I_flags.highlightSyntax) {
        NSRange range=NSIntersectionRange(aRange,NSMakeRange(0,[I_textStorage length]));
        if (range.length>0) {
            [I_textStorage removeAttribute:kSyntaxHighlightingIsCorrectAttributeName range:range];
            [[NSNotificationQueue defaultQueue] 
                enqueueNotification:[NSNotification notificationWithName:PlainTextDocumentSyntaxColorizeNotification object:self]
                       postingStyle:NSPostWhenIdle 
                       coalesceMask:NSNotificationCoalescingOnName | NSNotificationCoalescingOnSender 
                           forModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
        }
    }
}

- (void)performHighlightSyntax {
    if (!I_flags.isPerformingSyntaxHighlighting && I_flags.highlightSyntax && 
        [I_documentMode syntaxHighlighter]!=nil) {
        [self performSelector:@selector(highlightSyntaxLoop) withObject:nil afterDelay:0.3];                
        I_flags.isPerformingSyntaxHighlighting=YES;
    }
}

- (void)highlightSyntaxLoop {
    I_flags.isPerformingSyntaxHighlighting=NO;
    if (I_flags.highlightSyntax) {
        SyntaxHighlighter *highlighter=[I_documentMode syntaxHighlighter];
        if (highlighter && ![highlighter colorizeDirtyRanges:I_textStorage ofDocument: self]) {
            [self performHighlightSyntax];
        }
    }
}

#pragma mark -
#pragma mark ### Session Interaction ###
- (void)changeSelectionOfUserWithID:(NSString *)aUserID toRange:(NSRange)aRange {
    TCMMMUser *user=[[TCMMMUserManager sharedInstance] userForUserID:aUserID];
    NSMutableDictionary *properties=[user propertiesForSessionID:[[self session] sessionID]];
    if (!properties) {
        NSLog(@"Tried to change selection of user for session in which he isnt");
    } else {
        SelectionOperation *selectionOperation=[properties objectForKey:@"SelectionOperation"];
        if (selectionOperation) {
            [self invalidateLayoutForRange:[selectionOperation selectedRange]];
            [selectionOperation setSelectedRange:aRange];
        } else {
            [properties setObject:[SelectionOperation selectionOperationWithRange:aRange userID:aUserID] forKey:@"SelectionOperation"];
        }
        [self invalidateLayoutForRange:aRange];
    }
    [[NSNotificationQueue defaultQueue] 
    enqueueNotification:[NSNotification notificationWithName:PlainTextDocumentUserDidChangeSelectionNotification object:self userInfo:[NSDictionary dictionaryWithObject:user forKey:@"User"]]
           postingStyle:NSPostWhenIdle 
           coalesceMask:0
               forModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
    
    [self TCM_sendPlainTextDocumentParticipantsDidChangeNotification];
}


- (NSArray *)plainTextEditors {
    NSMutableArray *result = [NSMutableArray array];
    NSEnumerator *windowControllers=[[self windowControllers] objectEnumerator];
    PlainTextWindowController *windowController;
    while ((windowController=[windowControllers nextObject])) {
        [result addObjectsFromArray:[windowController plainTextEditors]];
    }
    return result;
}

- (void)handleOperation:(TCMMMOperation *)aOperation {
    if ([[aOperation operationID] isEqualToString:[TextOperation operationID]]) {
        // gather selections from all textviews and transform them
        NSArray *editors=[self plainTextEditors];
        NSMutableArray   *oldSelections=[NSMutableArray array];
        NSEnumerator *editorEnumerator=[editors objectEnumerator];
        PlainTextEditor *editor;
        while ((editor=[editorEnumerator nextObject])) {
            [oldSelections addObject:[SelectionOperation selectionOperationWithRange:[[editor textView] selectedRange] userID:@"doesn't matter"]];
        }


        I_flags.isRemotelyEditingTextStorage=YES;
        TextOperation *operation=(TextOperation *)aOperation;
        NSTextStorage *textStorage=[self textStorage];
        [textStorage beginEditing];
        [textStorage replaceCharactersInRange:[operation affectedCharRange]
                                   withString:[operation replacementString]];
        [textStorage addAttribute:WrittenByUserIDAttributeName value:[operation userID] 
                            range:NSMakeRange([operation affectedCharRange].location,
                                              [[operation replacementString] length])];
        [textStorage addAttribute:ChangedByUserIDAttributeName value:[operation userID] 
                            range:NSMakeRange([operation affectedCharRange].location,
                                              [[operation replacementString] length])];
        [textStorage endEditing];

        // set selection of all textviews
        TCMMMTransformator *transformator=[TCMMMTransformator sharedInstance];
        int index=0;
        for (index=0;index<(int)[editors count];index++) {
            SelectionOperation *selectionOperation = [oldSelections objectAtIndex:index];
            [transformator transformOperation:selectionOperation serverOperation:aOperation];
            editor = [editors objectAtIndex:index];
            [[editor textView] setSelectedRange:[selectionOperation selectedRange]];
        }

        I_flags.isRemotelyEditingTextStorage=NO;

    } else if ([[aOperation operationID] isEqualToString:[SelectionOperation operationID]]){
        [self changeSelectionOfUserWithID:[aOperation userID] 
              toRange:[(SelectionOperation *)aOperation selectedRange]];
    }
}

#pragma mark -
#pragma mark ### TextStorage Delegate Methods ###
- (void)textStorage:(NSTextStorage *)aTextStorage didReplaceCharactersInRange:(NSRange)aRange withString:(NSString *)aString {
    //NSLog(@"textStorage:%@ didReplaceCharactersInRange:%@ withString:%@",aTextStorage,NSStringFromRange(aRange),aString);
    TextOperation *textOp=[TextOperation textOperationWithAffectedCharRange:aRange replacementString:aString userID:[TCMMMUserManager myUserID]];
    if (!I_flags.isRemotelyEditingTextStorage) {
        [[self session] documentDidApplyOperation:textOp];
    } else {
        if ([aTextStorage length]==[aString length]) {
            [aTextStorage addAttributes:[self plainTextAttributes] range:NSMakeRange(0,[aString length])];
        }
    }
    if (I_flags.highlightSyntax) {
        if ([aString length]) {
            NSRange range=NSMakeRange(aRange.location,[aString length]);
            [self highlightSyntaxInRange:range];
        } else {
            unsigned length=[aTextStorage length];
            NSRange range=NSMakeRange(aRange.location!=0?aRange.location-1:aRange.location,length>=2?2:1);
            if (length>=NSMaxRange(range)) {
                [aTextStorage removeAttribute:kSyntaxHighlightingIsCorrectAttributeName range:range];
            }
            [self highlightSyntaxInRange:range];
        }        
    }

    if (I_flags.showMatchingBrackets &&
        ![[self undoManager] isUndoing] && ![[self undoManager] isRedoing] &&
        !I_flags.isRemotelyEditingTextStorage &&
//        !I_blockedit.isBlockediting && !I_blockedit.didBlockedit &&
        [aString length]==1 && 
        [self TCM_charIsBracket:[aString characterAtIndex:0]]) {
        I_bracketMatching.matchingBracketPosition=aRange.location;
    }
    [self triggerUpdateSymbolTableTimer];

// transform all selectedRanges
    TCMMMSession *session=[self session];
    NSString *sessionID=[session sessionID];
    NSEnumerator *participants=[[[session participants] objectForKey:@"ReadWrite"] objectEnumerator];
    BOOL didChangeAParticipant=NO;
    TCMMMUser *user=nil;
    TCMMMTransformator *transformator=[TCMMMTransformator sharedInstance];
    while ((user=[participants nextObject])) {
        SelectionOperation *selectionOperation=[[user propertiesForSessionID:sessionID] objectForKey:@"SelectionOperation"];
        if (selectionOperation) {
            NSRange oldRange=[selectionOperation selectedRange];
            [transformator transformOperation:selectionOperation serverOperation:textOp];
            if (!NSEqualRanges(oldRange,[selectionOperation selectedRange])) {
                [self invalidateLayoutForRange:oldRange];
                [self invalidateLayoutForRange:[selectionOperation selectedRange]];
                didChangeAParticipant=YES;
            }
        }
    }
    if (didChangeAParticipant) {
        [self TCM_sendPlainTextDocumentParticipantsDidChangeNotification];
    }
    
    if (I_webPreviewWindowController && 
        [[I_webPreviewWindowController window] isVisible] &&
        ([I_webPreviewWindowController refreshType]==kWebPreviewRefreshAutomatic || 
         [I_webPreviewWindowController refreshType]==kWebPreviewRefreshDelayed)) {
        [[NSNotificationQueue defaultQueue] 
    enqueueNotification:[NSNotification notificationWithName:PlainTextDocumentRefreshWebPreviewNotification object:self]
           postingStyle:NSPostWhenIdle 
           coalesceMask:NSNotificationCoalescingOnName | NSNotificationCoalescingOnSender 
               forModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];

    }
}

- (NSDictionary *)blockeditAttributesForTextStorage:(TextStorage *)aTextStorage {
    return [self blockeditAttributes];
}

- (void)textStorageDidStartBlockedit:(TextStorage *)aTextStorage {
    [[self plainTextEditors] makeObjectsPerformSelector:@selector(TCM_updateStatusBar)];
}

- (void)textStorageDidStopBlockedit:(TextStorage *)aTextStorage {
    [[self plainTextEditors] makeObjectsPerformSelector:@selector(TCM_updateStatusBar)];
}

#pragma mark -
#pragma mark ### TextView Notifications / Extended Delegate ###

- (BOOL)textView:(NSTextView *)aTextView doCommandBySelector:(SEL)aSelector {
//    NSLog(@"TextDocument textView doCommandBySelector:%@",NSStringFromSelector(aSelector));
    NSRange affectedRange=[aTextView rangeForUserTextChange];
    NSRange selectedRange=[aTextView selectedRange];
    if (aSelector==@selector(cancel:)) {
        TextStorage *textStorage=(TextStorage *)[self textStorage];
        if ([textStorage hasBlockeditRanges]) {
            [textStorage stopBlockedit];
            return YES;
        }
    } else if (aSelector==@selector(deleteBackward:)) {
        //NSLog(@"AffectedRange=%d,%d",affectedRange.location,affectedRange.length);
        if (affectedRange.length==0 && affectedRange.location>0) {
            if (!I_flags.usesTabs) {
                // when we have a tab we have to find the last linebreak
                NSString *string=[[self textStorage] string];
                NSRange lineRange=[string lineRangeForRange:affectedRange];
                unsigned firstCharacter=0;
                int position=affectedRange.location;
                while (--position>=lineRange.location) {
                    if (!firstCharacter && [string characterAtIndex:position]!=[@"\t" characterAtIndex:0] &&
                                           [string characterAtIndex:position]!=[@" " characterAtIndex:0]) {
                        firstCharacter=position+1;
                        break;
                    }
                }
                position=lineRange.location;
                //NSLog(@"last linebreak, firstcharacter=%d,%d",position,firstCharacter);
                if (firstCharacter==affectedRange.location 
                    || affectedRange.location==lineRange.location 
                    || firstCharacter) {
                    return NO;
                }
                int toDelete=(affectedRange.location-lineRange.location)%I_tabWidth;
                if (toDelete==0) {
                    toDelete=I_tabWidth; 
                }
                NSRange deleteRange;
                deleteRange.location=affectedRange.location-toDelete;
                deleteRange.length  =affectedRange.location-deleteRange.location;
                if ([aTextView shouldChangeTextInRange:deleteRange replacementString:@""]) {
                    [[aTextView textStorage] replaceCharactersInRange:deleteRange withString:@""];
                    [aTextView didChangeText];
                }
                return YES;
            }
        }    
    } else if (aSelector==@selector(insertNewline:)) {
        NSString *indentString=nil;
        if (I_flags.indentNewLines) {
            // when we have a newline, we have to find the last linebreak
            NSString    *string=[[self textStorage] string];
            NSRange indentRange=[string lineRangeForRange:affectedRange];        
            indentRange.length=0;
            while (NSMaxRange(indentRange)<affectedRange.location &&
                   ([string characterAtIndex:NSMaxRange(indentRange)]==[@" "  characterAtIndex:0] ||
                    [string characterAtIndex:NSMaxRange(indentRange)]==[@"\t" characterAtIndex:0])) {
                indentRange.length++;
            }
            if (indentRange.length) {
                indentString=[string substringWithRange:indentRange];
            }
        }
        if (indentString) {
            [aTextView insertText:[NSString stringWithFormat:@"%@%@",[self lineEndingString],indentString]];        
        } else {
            [aTextView insertText:[self lineEndingString]];
        }
        return YES;
        
    } 
    else if (aSelector==@selector(insertTab:) && !I_flags.usesTabs) {
        // when we have a tab we have to find the last linebreak
        NSRange lineRange=[[[self textStorage] string] lineRangeForRange:affectedRange];        
        NSString *replacementString=[@" " stringByPaddingToLength:I_tabWidth-((affectedRange.location-lineRange.location)%I_tabWidth)
                                                       withString:@" " startingAtIndex:0];
        [aTextView insertText:replacementString];
        return YES;
    } else if ((aSelector==@selector(moveLeft:) || aSelector==@selector(moveRight:)) &&
                I_flags.showMatchingBrackets) {
        unsigned int position=0;
        if (aSelector==@selector(moveLeft:)) {
            position=selectedRange.location-1;        
        } else {
            position=NSMaxRange(selectedRange);
        }
        NSString *string=[[self textStorage] string];
        if (position>=0 && position<[string length] && 
            [self TCM_charIsBracket:[string characterAtIndex:position]]) { 
            [self TCM_highlightBracketAtPosition:position inTextView:aTextView];
        }
    }
//    _flags.controlBlockedit=YES;
    return NO;
}

- (NSRange)textView:(NSTextView *)aTextView 
           willChangeSelectionFromCharacterRange:(NSRange)aOldSelectedCharRange 
                                toCharacterRange:(NSRange)aNewSelectedCharRange {
    TextStorage *textStorage = (TextStorage *)[aTextView textStorage];
    if (![textStorage isBlockediting] && [textStorage hasBlockeditRanges]) {
        unsigned positionToCheck=aNewSelectedCharRange.location;
        if (positionToCheck<[textStorage length] || positionToCheck!=0) {
            if (positionToCheck>=[textStorage length]) positionToCheck--;
            NSDictionary *attributes=[textStorage attributesAtIndex:positionToCheck effectiveRange:NULL];
            if (![attributes objectForKey:BlockeditAttributeName]) {
                [textStorage stopBlockedit];
            }
        }
    }
    
    if (([[NSApp currentEvent] type] == NSLeftMouseUp) && 
        ([[NSApp currentEvent] clickCount] == 2)) {
        
        NSLayoutManager *layoutManager=[aTextView layoutManager];
        NSPoint point = [aTextView convertPoint:[[NSApp currentEvent] locationInWindow] fromView:nil];
        point.x -= [aTextView textContainerOrigin].x;
        point.y -= [aTextView textContainerOrigin].y;
        unsigned glyphIndex=[layoutManager glyphIndexForPoint:point 
                                              inTextContainer:[aTextView textContainer]];
        NSRect    glyphRect=[layoutManager boundingRectForGlyphRange:NSMakeRange(glyphIndex, 1)
                                                     inTextContainer:[aTextView textContainer]];
        if (NSPointInRect(point, glyphRect)) {
            // Convert the glyph index to a character index
            unsigned charIndex=[layoutManager characterIndexForGlyphAtIndex:glyphIndex];
            NSString *string=[[self textStorage] string];
            if ([self TCM_charIsBracket:[string characterAtIndex:charIndex]]) {
                unsigned matchingPosition=[self TCM_positionOfMatchingBracketToPosition:charIndex];
                if (matchingPosition!=NSNotFound) {
                   aNewSelectedCharRange = NSUnionRange(NSMakeRange(charIndex,1),
                                                        NSMakeRange(matchingPosition,1));
                }
            }
        }
    }

    return aNewSelectedCharRange;
}


- (void)textViewDidChangeSelection:(NSNotification *)aNotification {
    if (!I_flags.isRemotelyEditingTextStorage) {
        NSRange selectedRange = [(NSTextView *)[aNotification object] selectedRange];
        SelectionOperation *selOp = [SelectionOperation selectionOperationWithRange:selectedRange userID:[TCMMMUserManager myUserID]];
        [[self session] documentDidApplyOperation:selOp];
    }
}

- (BOOL)textView:(NSTextView *)aTextView shouldChangeTextInRange:(NSRange)aAffectedCharRange replacementString:(NSString *)aReplacementString {

    TextStorage *textStorage=(TextStorage *)[aTextView textStorage];

    if ([textStorage hasBlockeditRanges] && ![textStorage isBlockediting] &&
        ![[self undoManager] isRedoing] && ![[self undoManager] isUndoing]) {
        if ([[NSApp currentEvent] type]==NSLeftMouseUp) {
            NSBeep();
            return NO;
        }
        static NSMutableCharacterSet *lineEndingSet=nil;
        if (!lineEndingSet) {
            unichar seps[2];
            seps[0]=0x2028;
            seps[1]=0x2029;
            NSString *unicodeLSEP=[NSString stringWithCharacters:seps   length:1];
            NSString *unicodePSEP=[NSString stringWithCharacters:seps+1 length:1];
            lineEndingSet=[[NSMutableCharacterSet characterSetWithCharactersInString:[NSString stringWithFormat:@"\n\r%@%@",unicodeLSEP,unicodePSEP]] retain];
        }
        
        NSRange wholeRange=NSMakeRange(0,[textStorage length]);
        NSString *string=[textStorage string];
        id value=[textStorage attribute:BlockeditAttributeName 
                    atIndex:(aAffectedCharRange.location < wholeRange.length)?
                            aAffectedCharRange.location : wholeRange.length-1 
                    longestEffectiveRange:nil inRange:wholeRange];
        if (value) {
            NSRange foundRange=[string rangeOfCharacterFromSet:lineEndingSet options:0 range:aAffectedCharRange];
            if (foundRange.location!=NSNotFound) {
                NSBeep();
                return NO;
            }
            foundRange=[aReplacementString rangeOfCharacterFromSet:lineEndingSet];
            if (foundRange.location!=NSNotFound) {
                NSBeep();
                return NO;
            }

            if (![textStorage didBlockedit]) {
                [[self undoManager] beginUndoGrouping];

                int tabWidth=[self tabWidth];
                NSRange lineRange=[string lineRangeForRange:aAffectedCharRange];
                unsigned locationLength=[string
                    detabbedLengthForRange:NSMakeRange(lineRange.location,aAffectedCharRange.location-lineRange.location) 
                                  tabWidth:tabWidth];
                unsigned length=[string
                    detabbedLengthForRange:NSMakeRange(lineRange.location,NSMaxRange(aAffectedCharRange)-lineRange.location) 
                                  tabWidth:tabWidth];
        //        lineRange.location=_flags.didBlockeditRange.location-lineRange.location;
                [textStorage setDidBlockedit:YES];
                [textStorage setDidBlockeditRange:aAffectedCharRange];
                [textStorage setDidBlockeditLineRange:NSMakeRange(locationLength,length-locationLength)];
            }
        } else {
            [textStorage stopBlockedit];
        }
        
    }
    
    return YES;
}

- (void)textDidChange:(NSNotification *)aNotification {
    NSTextView *textView=[aNotification object];
    if (I_bracketMatching.matchingBracketPosition!=NSNotFound) {
        [self TCM_highlightBracketAtPosition:I_bracketMatching.matchingBracketPosition inTextView:textView];
        I_bracketMatching.matchingBracketPosition=NSNotFound;
    }

    TextStorage *textStorage = (TextStorage *) [textView textStorage];
    // take care for blockedit
    
    if ([textStorage didBlockedit] && ![textStorage isBlockediting] && ![textView hasMarkedText]) {
        NSRange lineRange=[textStorage didBlockeditLineRange];
        NSRange selectedRange=[textView selectedRange];
        NSRange didBlockeditRange=[textStorage didBlockeditRange];
        NSString *replacementString=[[textStorage string] 
                                        substringWithRange:NSMakeRange(didBlockeditRange.location,
                                                                       selectedRange.location-didBlockeditRange.location)];
        NSRange wholeRange=NSMakeRange(0,[textStorage length]);
        NSRange blockeditRange=NSMakeRange(wholeRange.length,0);
        NSRange newSelectedRange=NSMakeRange(NSNotFound,0);
        int lengthChange=0;
        NSRange tempRange;
        while (blockeditRange.location!=0) {
            id value=[textStorage attribute:BlockeditAttributeName atIndex:blockeditRange.location-1 
                              longestEffectiveRange:&blockeditRange inRange:wholeRange];
 
            if (value) {
                if ((!DisjointRanges(blockeditRange,selectedRange) ||
                           selectedRange.location==blockeditRange.location ||
                       NSMaxRange(blockeditRange)==selectedRange.location)) {
                    [textStorage setIsBlockediting:YES];
                    NSRange lineRangeToExclude=[[textStorage string] lineRangeForRange:NSMakeRange(selectedRange.location,0)];
                    if (NSMaxRange(blockeditRange)>NSMaxRange(lineRangeToExclude)) {
                        [textStorage blockChangeTextInRange:lineRange
                                          replacementString:replacementString
                                             paragraphRange:NSMakeRange(NSMaxRange(lineRangeToExclude),
                                                                 NSMaxRange(blockeditRange)-NSMaxRange(lineRangeToExclude)) 
                                          inTextView:textView];
//                        NSLog(@"Edited Block after");
                    }
                    newSelectedRange=[textView selectedRange];
                    if (blockeditRange.location<lineRangeToExclude.location) {
                        NSRange otherRange;
                        tempRange=
                        [textStorage blockChangeTextInRange:lineRange
                                          replacementString:replacementString
                                             paragraphRange:(otherRange=NSMakeRange(blockeditRange.location,
                                                                 lineRangeToExclude.location-blockeditRange.location)) 
                                                 inTextView:textView];
//                        NSLog(@"Edited Block before");
                        lengthChange+=tempRange.length-otherRange.length;
                    }
                    [textStorage setIsBlockediting:NO];
                } else {
                    [textStorage setIsBlockediting:YES];
                    tempRange=
                    [textStorage blockChangeTextInRange:lineRange
                                      replacementString:replacementString
                                         paragraphRange:blockeditRange 
                                             inTextView:textView];
    //                        NSLog(@"Edited Block");
                    if (newSelectedRange.location!=NSNotFound) {
                        lengthChange+=tempRange.length-blockeditRange.length;
                    }
                    [textStorage setIsBlockediting:NO];
                } 
            }
        }
        [textStorage setDidBlockedit:NO];
        [[self undoManager] endUndoGrouping];
        newSelectedRange.location+=lengthChange;
        if (!NSEqualRanges(newSelectedRange,[textView selectedRange])) {
            [textView setSelectedRange:newSelectedRange];
        }
    }
}



@end
