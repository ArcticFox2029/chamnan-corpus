//
//  OrbitalFreightDriver-Bridging-Header.h
//  OrbitalFreightDriver
//

/**
 @brief Expone al lado Swift los dos módulos de Objective-C que quedan en el proyecto.

 @discussion
 No es una lista pendiente de migrar. Son los dos únicos sitios donde el código antiguo sigue siendo
 el mejor código disponible: la aritmética del dígito de control de ISO 6346 y las reglas de
 normalización de precintos por transitario. Todo lo demás —red, cola sin conexión, cámara— es
 Swift, y nada nuevo debería entrar aquí.
 */

#import "OFLegacyContainerCodeValidator.h"
#import "OFLegacySealReader.h"
