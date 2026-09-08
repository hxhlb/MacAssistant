<p align="center">
  <img src="assets/app-icon.png" width="96" alt="MacAssistant">
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">
  Нативный набор для macOS: обслуживание, клоны, ремонт приложений, команды и сайдлоад.
</p>

<p align="center">
  <a href="../README.md">English</a>
  · <a href="README.zh-CN.md">简体中文</a>
  · <a href="README.es.md">Español</a>
  · <a href="README.ko.md">한국어</a>
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
  <img src="assets/macassistant-hero-brand.png" alt="Обзор системы" width="880">
</p>

<p align="center">
  <sub>Живые CPU, память, диск и батарея. Скриншоты на упрощённом китайском; шесть языков — в «О программе».</sub>
</p>

## Основные возможности

<table>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/system-cleanup.png" alt="Очистка" width="430">
      <br>
      <b>Очистка</b><br>
      Кэши, Derived Data, Docker и Time Machine — сначала просмотр. Только домашний каталог.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/app-clones.png" alt="Клоны" width="430">
      <br>
      <b>Клоны приложений</b><br>
      Изолированные копии WeChat, браузеров и редакторов, с отдельным прокси.
    </td>
  </tr>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/desktop-icons.png" alt="Значки" width="430">
      <br>
      <b>Значки рабочего стола</b><br>
      Перекраска значков Finder для файлов, папок и приложений.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/ipa-workbench.png" alt="IPA" width="430">
      <br>
      <b>IPA-верстак</b><br>
      Внедрение плагинов, сжатие, заголовки, подпись. Beta.
    </td>
  </tr>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/mac-inject.png" alt="Внедрение" width="430">
      <br>
      <b>Внедрение в Mac-приложения</b><br>
      Внедрение dylib в локальный <code>.app</code>. Beta.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/environment.png" alt="Окружение" width="430">
      <br>
      <b>Проверка окружения</b><br>
      Находит недостающие инструменты и подсказывает установку.
    </td>
  </tr>
</table>

### Другие функции

| Повседневное | Разработка |
| --- | --- |
| Ремонт App (повреждено, карантин, подписи) | DEB: создать, проверить, конвертировать, пересобрать |
| Живое давление памяти и процессы | DYLIB: зависимости, install name, rpath |
| Сеть: скорость, порты, ping, DNS, внешний IP | IPA: установка / извлечение как есть (без FairPlay) |
| Поиск команд с метками риска | Mach-O и class-dump |
| Переключатели Finder, скриншотов, скрытых файлов | Послойная подпись и Apple ID |

Предпросмотр перед удалением. Открытый код, без телеметрии.

Фоны, боковая панель, цвет значков и шесть языков — в **«О программе»**.

## Загрузка

[Releases](https://github.com/iosrxwy/MacAssistant/releases) · macOS 13+ · Apple Silicon и Intel.

### macOS блокирует первый запуск?

> [!IMPORTANT]
> Эта версия подписана **ad-hoc и не нотаризована**. Откройте приложение один раз, затем **Системные настройки → Конфиденциальность и безопасность → Всё равно открыть**. Не отключайте Gatekeeper.

## Сборка

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
```

## Участники

<table>
  <tr>
    <td align="center" width="120">
      <a href="https://github.com/iosrxwy"><img src="https://github.com/iosrxwy.png?size=120" width="72" height="72" alt="iosrxwy"></a><br>
      <a href="https://github.com/iosrxwy"><b>iosrxwy</b></a><br>
      <sub>Автор</sub>
    </td>
    <td align="center" width="120">
      <a href="https://github.com/codex"><img src="https://github.com/codex.png?size=120" width="72" height="72" alt="Codex"></a><br>
      <a href="https://github.com/codex"><b>Codex</b></a><br>
      <sub>Разработка</sub>
    </td>
    <td align="center" width="120">
      <a href="https://x.ai/grok"><img src="https://github.com/xai-org.png?size=120" width="72" height="72" alt="Grok Build"></a><br>
      <a href="https://x.ai/grok"><b>Grok Build</b></a><br>
      <sub>Разработка</sub>
    </td>
  </tr>
</table>

Thanks: [AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign) · [ATBClone](https://github.com/aitobox/ATBClone)

[GNU GPL-3.0](../LICENSE). Распространяемые изменения должны оставаться свободным ПО под той же лицензией, с полным соответствующим исходным кодом.

[SECURITY.md](../SECURITY.md)
