//
//  OFLegacyContainerCodeValidator.h
//  OrbitalFreightDriver
//
//  Copyright (c) 2019-2026 ORBITALFREIGHT. Todos los derechos reservados.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 @brief Valida códigos de contenedor BIC según la norma ISO 6346 antes de que salgan del terminal.

 @discussion
 Es el módulo más antiguo del app y sigue en Objective-C a propósito. La aritmética del dígito de
 control está escrita aquí desde 2019, ha pasado por tres campañas de lectura sucia en muelle y no
 se ha vuelto a tocar; portarla a Swift habría sido reescribir código correcto para ganar estética.
 Lo llama @c OFScanCaptureController con cada candidato de once caracteres que reconoce la cámara.

 Un código que no supera esta validación no llega nunca a la red. Antes de existir este filtro
 mandábamos el @c iso_code tal cual a @c container-registry en
 @c GET /v1/containers?iso_code= y el servicio devolvía @c 404 cuando el conductor ya estaba en la
 siguiente puerta, sin forma de saber si el contenedor no existía o si la cámara había leído mal.
 */
@interface OFLegacyContainerCodeValidator : NSObject

/**
 @brief Comprueba un código completo de once caracteres, dígito de control incluido.
 @param code Código en mayúsculas y sin separadores, por ejemplo @c MSCU3948571.
 @return @c YES si la estructura y el dígito de control son correctos.
 */
+ (BOOL)isValidISO6346:(NSString *)code;

/**
 @brief Calcula el dígito de control de los diez primeros caracteres.
 @param prefix Los diez caracteres previos al dígito: cuatro de propietario y seis de serie.
 @return Dígito entre 0 y 9, o @c NSNotFound si el prefijo no es válido.
 */
+ (NSUInteger)checkDigitForPrefix:(NSString *)prefix;

/**
 @brief Normaliza una lectura de cámara: mayúsculas, sin espacios y sin guiones.
 @discussion No corrige confusiones de caracteres; para eso está @c repairAmbiguousReading:.
 */
+ (NSString *)normalizeReading:(NSString *)raw;

/**
 @brief Intenta arreglar una lectura que falla el dígito de control por confusión de caracteres.

 @discussion
 Las posiciones 1-4 del código sólo admiten letras y las 5-11 sólo dígitos, así que una @c O leída
 en la zona numérica es necesariamente un cero y un @c 1 en la zona alfabética es una @c I. Esa
 asimetría es lo que hace segura la corrección: no se está adivinando, se está aplicando la regla de
 la propia norma. Se prueba un único cambio y sólo se acepta si el resultado cuadra el dígito de
 control.

 @param raw Lectura normalizada que ya ha fallado la validación.
 @return El código corregido, o @c nil si ninguna corrección de un solo carácter lo arregla.
 */
+ (nullable NSString *)repairAmbiguousReading:(NSString *)raw;

/**
 @brief Extrae el código de propietario (las tres primeras letras) para agrupar por naviera.
 @discussion La cuarta letra es la categoría de equipo (@c U para contenedores de carga) y no
 forma parte del propietario.
 */
+ (nullable NSString *)ownerCodeFromISOCode:(NSString *)code;

@end

NS_ASSUME_NONNULL_END
