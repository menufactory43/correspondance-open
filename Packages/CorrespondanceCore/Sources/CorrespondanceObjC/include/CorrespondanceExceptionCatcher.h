#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Attrape une exception Objective-C pour que Swift puisse la traiter.
///
/// Swift ne sait pas rattraper les exceptions d'AppKit : elles traversent la
/// pile et tuent le processus. Or certaines écritures sur une `NSWindow`
/// lèvent — poser un `contentMaxSize` inférieur au `contentMinSize` fait lever
/// `_postWindowNeedsUpdateConstraints`, et l'app meurt au lancement par un
/// `SIGABRT`.
///
/// Une garde de confort ne doit jamais pouvoir tuer l'app. Le pire cas
/// acceptable est une fenêtre mal dimensionnée, jamais un plantage.
@interface CorrespondanceExceptionCatcher : NSObject

/// Exécute `block`. Rend `nil` si tout s'est bien passé, l'exception sinon.
+ (NSException *_Nullable)catchException:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
