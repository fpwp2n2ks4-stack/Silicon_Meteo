//
//  main.swift
//  Point d'entrée explicite
//
//  On n'utilise pas `@main` ici : avec cette annotation, Swift s'appuie sur
//  l'implémentation par défaut de `static func main()` fournie par AppKit
//  pour `NSApplicationDelegate`. Sur ce SDK, ce chemin démarre le processus
//  mais n'appelle jamais `applicationDidFinishLaunching` — l'application
//  reste vivante, sans icône et sans rien collecter. Le point d'entrée est
//  donc écrit à la main : c'est aussi plus lisible.
//
//  Le delegate doit être conservé par une variable forte : `NSApplication
//  .delegate` est `weak`, donc un temporaire passé directement serait
//  libéré avant le début de la boucle d'événements.
//

import AppKit

let application = NSApplication.shared
let appDelegate = AppDelegate()

application.delegate = appDelegate
// Avant `run()` : sinon l'agent apparaît brièvement dans le Dock.
application.setActivationPolicy(.accessory)
application.run()
