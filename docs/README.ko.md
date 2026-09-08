<p align="center">
  <img src="assets/app-icon.png" width="96" alt="MacAssistant">
</p>

<h1 align="center">MacAssistant</h1>

<p align="center">
  네이티브 macOS 도구 모음: 시스템 관리, 앱 분신, 앱 복구, 명령 검색, 사이드로드.
</p>

<p align="center">
  <a href="../README.md">English</a>
  · <a href="README.zh-CN.md">简体中文</a>
  · <a href="README.es.md">Español</a>
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
  <img src="assets/macassistant-hero-brand.png" alt="시스템 개요" width="880">
</p>

<p align="center">
  <sub>실시간 CPU·메모리·디스크·배터리. 스크린샷은 간체 중문, 언어는 정보 페이지에서 바꿀 수 있습니다.</sub>
</p>

## 일반 기능

<table>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/system-cleanup.png" alt="시스템 정리" width="430">
      <br>
      <b>시스템 정리</b><br>
      캐시, Derived Data, Docker, Time Machine을 미리 본 뒤 삭제. 홈 디렉터리만.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/app-clones.png" alt="앱 분신" width="430">
      <br>
      <b>앱 분신</b><br>
      위챗·브라우저·편집기의 독립 데이터 복사본. 분신별 프록시 가능.
    </td>
  </tr>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/desktop-icons.png" alt="데스크톱 아이콘" width="430">
      <br>
      <b>데스크톱 아이콘</b><br>
      파일·폴더·앱의 Finder 아이콘 색을 바꿉니다.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/ipa-workbench.png" alt="IPA" width="430">
      <br>
      <b>IPA 작업대</b><br>
      플러그인 주입, 슬림화, 헤더 추출, 서명. Beta.
    </td>
  </tr>
  <tr>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/mac-inject.png" alt="주입" width="430">
      <br>
      <b>Mac 앱 주입</b><br>
      로컬 <code>.app</code>에 dylib 주입. Beta.
    </td>
    <td align="center" width="50%" valign="top">
      <img src="assets/screenshots/environment.png" alt="환경 검사" width="430">
      <br>
      <b>환경 검사</b><br>
      없는 도구를 찾고 설치 방법을 안내합니다.
    </td>
  </tr>
</table>

### 기타 기능

| 일상 | 개발 |
| --- | --- |
| 앱 복구(손상, 격리, 서명) | DEB 제작, 검사, 변환, 다시 패키징 |
| 실시간 메모리 압력과 프로세스 관리 | DYLIB 의존성, 설치 이름, rpath |
| 네트워크: 속도, 포트, ping, DNS, 공인 IP | IPA 설치 / 원본 추출(FairPlay 덤프 없음) |
| 위험 표시가 있는 명령 검색 | Mach-O, class-dump |
| Finder, 스크린샷, 숨김 파일 빠른 전환 | 계층 서명과 Apple ID 서명 |

삭제 전 미리보기. 오픈 소스, 텔레메트리 없음.

배경, 사이드바, 아이콘 색, 6개 언어는 **정보** 페이지.

## 다운로드

[Releases](https://github.com/iosrxwy/MacAssistant/releases) · macOS 13+ · Apple Silicon 및 Intel.

### 첫 실행이 차단되나요?

> [!IMPORTANT]
> 이 버전은 **ad-hoc이며 공증되지 않았습니다.** 한 번 연 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**. Gatekeeper를 끄지 마세요.

## 빌드

```bash
git clone https://github.com/iosrxwy/MacAssistant.git
cd MacAssistant
./build_app.sh release universal
```

## 기여자

<table>
  <tr>
    <td align="center" width="120">
      <a href="https://github.com/iosrxwy"><img src="https://github.com/iosrxwy.png?size=120" width="72" height="72" alt="iosrxwy"></a><br>
      <a href="https://github.com/iosrxwy"><b>iosrxwy</b></a><br>
      <sub>작성자</sub>
    </td>
    <td align="center" width="120">
      <a href="https://github.com/codex"><img src="https://github.com/codex.png?size=120" width="72" height="72" alt="Codex"></a><br>
      <a href="https://github.com/codex"><b>Codex</b></a><br>
      <sub>개발</sub>
    </td>
    <td align="center" width="120">
      <a href="https://x.ai/grok"><img src="https://github.com/xai-org.png?size=120" width="72" height="72" alt="Grok Build"></a><br>
      <a href="https://x.ai/grok"><b>Grok Build</b></a><br>
      <sub>개발</sub>
    </td>
  </tr>
</table>

Thanks: [AltSign](https://github.com/rileytestut/AltSign) / [AltStore](https://github.com/altstoreio/AltStore) · [xtool](https://github.com/xtool-org/xtool) · [libimobiledevice](https://libimobiledevice.org) · [Theos](https://github.com/theos/theos) · [zsign](https://github.com/zhlynn/zsign) · [ATBClone](https://github.com/aitobox/ATBClone)

[GNU GPL-3.0](../LICENSE). 배포하는 수정본은 같은 라이선스로 완전한 대응 소스와 함께 제공해야 합니다.

[SECURITY.md](../SECURITY.md)
