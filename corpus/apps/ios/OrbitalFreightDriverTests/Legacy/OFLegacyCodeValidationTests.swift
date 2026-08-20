//
//  OFLegacyCodeValidationTests.swift
//  OrbitalFreightDriverTests
//

import XCTest
@testable import OrbitalFreightDriver

/// Red de seguridad de los dos módulos de Objective-C, que son los que deciden qué códigos y qué
/// precintos llegan a salir del terminal.
///
/// Cada caso de aquí abajo corresponde a un incidente real de muelle. No están para subir la
/// cobertura: están porque la aritmética de ISO 6346 y las reglas por transitario se tocan una vez
/// cada dos años, siempre con prisa, y sin estas pruebas el fallo aparece un mes después en forma
/// de `404` de `container-registry` con el conductor ya en otro país.
final class OFLegacyCodeValidationTests: XCTestCase {

    // MARK: - Dígito de control

    func testKnownGoodCodesValidate() {
        XCTAssertTrue(OFLegacyContainerCodeValidator.isValidISO6346("CSQU3054383"))
        XCTAssertTrue(OFLegacyContainerCodeValidator.isValidISO6346("TGHU1203545"))
    }

    func testWrongCheckDigitFails() {
        // Mismo prefijo que el caso bueno, dígito de control cambiado a mano.
        XCTAssertFalse(OFLegacyContainerCodeValidator.isValidISO6346("CSQU3054384"))
    }

    func testTranspositionIsCaught() {
        // El error humano más frecuente al teclear un código a mano: dos dígitos intercambiados.
        // 305438 -> 304538, con el dígito de control original.
        XCTAssertFalse(OFLegacyContainerCodeValidator.isValidISO6346("CSQU3045383"))
    }

    /// El caso que nos costó un mes en producción: resto 11 igual a 10.
    ///
    /// La norma dice que ese resto se escribe como `0`, no que el código sea inválido. La primera
    /// versión devolvía 10 y comparaba contra un carácter, así que rechazaba un contenedor de cada
    /// once — un patrón lo bastante aleatorio como para parecer un problema de la cámara.
    func testRemainderOfTenIsWrittenAsZero() {
        XCTAssertEqual(OFLegacyContainerCodeValidator.checkDigit(forPrefix: "HLXU200007"), 0)
        XCTAssertTrue(OFLegacyContainerCodeValidator.isValidISO6346("HLXU2000070"))
    }

    func testLetterWeightsSkipMultiplesOfEleven() {
        // A vale 10 y a partir de ahí se salta 11, 22 y 33. Si alguien "simplifica" la tabla a un
        // rango contiguo, todo lo que lleve L, V o cualquier letra posterior deja de validar, y no
        // se nota hasta que aparece un contenedor de una naviera con esas iniciales.
        XCTAssertEqual(OFLegacyContainerCodeValidator.checkDigit(forPrefix: "KKKU000000"), 7)
        XCTAssertNotEqual(
            OFLegacyContainerCodeValidator.checkDigit(forPrefix: "LLLU000000"),
            OFLegacyContainerCodeValidator.checkDigit(forPrefix: "KKKU000000")
        )
    }

    // MARK: - Estructura

    func testEquipmentCategoryIsRestricted() {
        // La cuarta letra es la categoría de equipo. `U` es carga, `J` equipo desmontable y `Z`
        // chasis, que existe en la flota porque `fleet.vehicles.vehicle_class` incluye 'chassis'.
        XCTAssertFalse(OFLegacyContainerCodeValidator.isValidISO6346("CSQA3054383"))
    }

    func testShortAndLongReadingsAreRejected() {
        XCTAssertFalse(OFLegacyContainerCodeValidator.isValidISO6346("CSQU305438"))
        XCTAssertFalse(OFLegacyContainerCodeValidator.isValidISO6346("CSQU30543833"))
    }

    // MARK: - Normalización y reparación

    func testNormalisationStripsWhatThePaintAdds() {
        // Así viene pintado en la puerta: en grupos y con separadores.
        XCTAssertEqual(
            OFLegacyContainerCodeValidator.normalizeReading("csqu 305 438 3"),
            "CSQU3054383"
        )
    }

    func testSingleCharacterRepairFixesOCRConfusion() {
        // La cámara lee la O de la zona numérica como letra. En esa zona sólo puede haber dígitos,
        // así que la corrección no es una adivinanza sino la regla de la propia norma.
        XCTAssertEqual(
            OFLegacyContainerCodeValidator.repairAmbiguousReading("CSQU3O54383"),
            "CSQU3054383"
        )
    }

    func testRepairRefusesTwoCorrections() {
        // Con dos cambios se puede "arreglar" un código hasta convertirlo en otro contenedor real,
        // y eso ya no lo detecta ninguna validación posterior: `container-registry` respondería
        // con el envío equivocado y el escaneo quedaría atribuido a otra carga.
        XCTAssertNil(OFLegacyContainerCodeValidator.repairAmbiguousReading("CSQU3O5438B"))
    }

    func testOwnerCodeDropsTheEquipmentCategory() {
        XCTAssertEqual(OFLegacyContainerCodeValidator.ownerCode(fromISOCode: "CSQU3054383"), "CSQ")
    }

    // MARK: - Precintos

    func testSealPrefixesAreStrippedLongestFirst() {
        // El orden de la tabla de prefijos es obligatorio. Con `S-` antes que `SEAL-`, el primer
        // prefijo se comía la S y dejaba `EAL1234`, que no coincide con nada de lo que consta en
        // `freight.shipment_containers.seal_number`.
        XCTAssertEqual(OFLegacySealReader.normalizeSealNumber("SEAL-004821"), "4821")
        XCTAssertEqual(OFLegacySealReader.normalizeSealNumber("S-004821"), "4821")
    }

    func testLeadingZeroesOnlyDropForNumericSeals() {
        // El mismo precinto físico llega rellenado a ocho posiciones en una terminal y a seis en
        // otra. En un precinto alfanumérico, en cambio, el cero inicial sí distingue.
        XCTAssertEqual(OFLegacySealReader.normalizeSealNumber("00123456"), "123456")
        XCTAssertEqual(OFLegacySealReader.normalizeSealNumber("0A12345"), "0A12345")
    }

    func testMatchingIgnoresFormattingOnly() {
        XCTAssertTrue(OFLegacySealReader.sealNumber("SEAL 12 34 56", matchesSealNumber: "seal-123456"))
        XCTAssertFalse(OFLegacySealReader.sealNumber("123456", matchesSealNumber: "123457"))
    }

    func testGS1LabelsAreNotMistakenForSeals() {
        // La etiqueta logística de la mercancía comparte simbología con los precintos de medio
        // sector, y el conductor la lee sin querer al apuntar a la caja de al lado. Si pasara el
        // filtro, un `seal_check` compararía el precinto contra un número de bulto y daría
        // manipulación donde no la hay.
        XCTAssertFalse(OFLegacySealReader.looksLikeSealNumber("00340123451234567895"))
        XCTAssertTrue(OFLegacySealReader.looksLikeSealNumber("SEAL-1234567"))
    }
}
