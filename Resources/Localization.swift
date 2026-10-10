//
//  Localization.swift
//  Support multilingue de l'interface (FR/EN/ES)
//
//  Aucune dépendance externe : uniquement Foundation (`NSLocalizedString`,
//  `Bundle`, `UserDefaults`). Les clés de traduction sont le texte anglais :
//  si une traduction manque, l'anglais s'affiche automatiquement — la langue
//  de base n'a donc pas besoin de table dédiée.
//

import Foundation

/// Gestionnaire de la langue de l'interface.
///
/// La langue suit celle du système par défaut ; l'utilisateur peut la forcer
/// via le menu (mémorisé dans `UserDefaults`). Le bundle du `.lproj` choisi
/// est mis en cache et invalidé à chaque changement.
enum Localization {

    /// Langues proposées, dans l'ordre d'affichage du menu.
    static let supported: [(code: String, name: String)] = [
        ("en", "English"),
        ("fr", "Français"),
        ("es", "Español"),
    ]

    private static let preferenceKey = "appLanguage"

    /// Code de la langue active : préférence utilisateur, sinon langue système.
    static var current: String {
        if let saved = UserDefaults.standard.string(forKey: preferenceKey),
           supported.contains(where: { $0.code == saved }) {
            return saved
        }
        let system = Locale.preferredLanguages.first ?? "en"
        return supported.first { system.hasPrefix($0.code) }?.code ?? "en"
    }

    /// Force la langue voulue et invalide le bundle mis en cache.
    static func set(_ code: String) {
        guard supported.contains(where: { $0.code == code }) else { return }
        UserDefaults.standard.set(code, forKey: preferenceKey)
        cachedCode = nil
        cachedBundle = nil
    }

    private static var cachedCode: String?
    private static var cachedBundle: Bundle?

    /// Bundle du `.lproj` correspondant à la langue active.
    ///
    /// Retombe sur `Bundle.main` si le dossier est absent (par exemple dans
    /// les outils `verify`, qui n'embarquent pas les ressources de langue) :
    /// `NSLocalizedString` renvoie alors la clé, c'est-à-dire l'anglais.
    static var bundle: Bundle {
        let code = current
        if cachedCode == code, let cachedBundle { return cachedBundle }

        let resolved: Bundle
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let specialized = Bundle(path: path) {
            resolved = specialized
        } else {
            resolved = .main
        }

        cachedCode = code
        cachedBundle = resolved
        return resolved
    }
}

/// Traduit une clé puis applique d'éventuels arguments de format.
///
/// Les clés sont le texte anglais (ex. `"Core %d"`) et les traductions vivent
/// dans `Resources/<code>.lproj/Localizable.strings`. Les formats utilisent des
/// spécificateurs positionnels (`%1$@`, `%2$d`) afin que l'ordre des mots
/// puisse différer d'une langue à l'autre.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: Localization.bundle, comment: "")
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
