<p align="center">
  <img src="assets/app-icon.png" width="96" alt="MacAssistant">
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">
  Caja de herramientas nativa de macOS: mantenimiento, clones, reparación, comandos y sideload.
</p>

<p align="center">
  <a href="../README.md">English</a>
  · <a href="README.zh-CN.md">简体中文</a>
  · <a href="README.ko.md">한국어</a>
  · <a href="README.ru.md">Русский</a>
</p>

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/actions/workflows/ci.yml"><img src="https://github.com/iosrxwy/MacAssistant/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+">
  <a href="../LICENSE"><img src="https://img.shields.io/github/license/iosrxwy/MacAssistant" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="https://github.com/iosrxwy/MacAssistant/releases"><img src="https://img.shields.io/badge/Download-Releases-0A84FF?style=flat-square&logo=apple&logoColor=white" alt="Download"></a>
  <a href="https://x.com/iOSRXWY"><img src="https://img.shields.io/badge/X-@iOSRXWY-111111?style=flat-square&logo=x&logoColor=white" alt="X"></a>
  <a href="https://t.me/iosrxwy"><img src="https://img.shields.io/badge/Telegram-@iosrxwy-26A5E4?style=flat-square&logo=telegram&logoColor=white" alt="Telegram"></a>
</p>

<p align="center">
  <img src="assets/macassistant-hero-brand.png" alt="Resumen del sistema" width="880">
</p>

<p align="center">
  <sub>CPU, memoria, disco y batería en vivo. Capturas en chino simplificado; seis idiomas en Acerca de.</sub>
</p>

## Funciones habituales

<table>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/system-cleanup.png" alt="Limpieza" width="430">
      <br>
      <b>Limpieza</b><br>
      Vista previa de cachés, Derived Data, Docker y Time Machine. Solo el directorio de usuario.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/app-clones.png" alt="Clones de apps" width="430">
      <br>
      <b>Clones de apps</b><br>
      Copias aisladas de WeChat, navegadores y editores, con proxy opcional.
    </td>
  </tr>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/desktop-icons.png" alt="Iconos de escritorio" width="430">
      <br>
      <b>Iconos de escritorio</b><br>
      Recolorea iconos de Finder para archivos, carpetas y apps.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/ipa-workbench.png" alt="IPA" width="430">
      <br>
      <b>Mesa de trabajo IPA</b><br>
      Inyecta plugins, aligera, extrae cabeceras y firma. Beta.
    </td>
  </tr>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/mac-inject.png" alt="Inyección" width="430">
      <br>
      <b>Inyección en apps Mac</b><br>
      Inyecta un dylib en un <code>.app</code> local. Beta.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/environment.png" alt="Entorno" width="430">
      <br>
      <b>Comprobación de entorno</b><br>
      Detecta herramientas que faltan y muestra cómo instalarlas.
    </td>
  </tr>
</table>

### Otras funciones

| Día a día | Desarrollo |
| --- | --- |
| Reparación de apps (dañadas, cuarentena, firmas) | DEB: crear, inspeccionar, convertir, reempaquetar |
| Memoria en vivo y gestión de procesos | DYLIB: dependencias, nombres de instalación, rpath |
| Red: velocidad, puertos, ping, DNS, IP pública | IPA: instalar / extraer tal cual (sin FairPlay) |
| Biblioteca de comandos con etiquetas de riesgo | Mach-O y class-dump |
| Interruptores de Finder, capturas, archivos ocultos | Firma por capas y Apple ID |

Vista previa antes de borrar. Código abierto, sin telemetría.

Fondos de página, barra lateral, color de iconos y seis idiomas en **Acerca de**.

## Descarga

[Releases](https://github.com/iosrxwy/MacAssistant/releases) · macOS 13+ · Apple Silicon e Intel.

### ¿macOS bloquea el primer inicio?

> [!IMPORTANT]
> Esta versión está **firmada ad-hoc y no notarizada**. Ábrela una vez, luego **Ajustes del Sistema → Privacidad y seguridad → Abrir de todos modos**. No desactives Gatekeeper.

## Compilar

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
```

## Colaboradores

<table>
  <tr>
    <td align="center" width="120">
      <a href="https://github.com/iosrxwy"><img src="https://github.com/iosrxwy.png?size=120" width="72" height="72" alt="iosrxwy"></a><br>
      <a href="https://github.com/iosrxwy"><b>iosrxwy</b></a><br>
      <sub>Autor</sub>
    </td>
    <td align="center" width="120">
      <a href="https://github.com/codex"><img src="https://github.com/codex.png?size=120" width="72" height="72" alt="Codex"></a><br>
      <a href="https://github.com/codex"><b>Codex</b></a><br>
      <sub>Desarrollo</sub>
    </td>
    <td align="center" width="120">
      <a href="https://x.ai/grok"><img src="https://github.com/xai-org.png?size=120" width="72" height="72" alt="Grok Build"></a><br>
      <a href="https://x.ai/grok"><b>Grok Build</b></a><br>
      <sub>Desarrollo</sub>
    </td>
  </tr>
</table>

Gracias: [AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign) · [ATBClone](https://github.com/aitobox/ATBClone)

[GNU GPL-3.0](../LICENSE). Las modificaciones distribuidas deben seguir siendo software libre bajo la misma licencia, con el código fuente correspondiente.

[SECURITY.md](../SECURITY.md)
