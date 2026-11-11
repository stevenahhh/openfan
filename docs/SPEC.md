# OpenFan 구현 스펙

질의: 이 맥(MacBook Pro Mac17,9, Apple M5 Pro, macOS 27.0.1)에서 직접 만든 메뉴바 앱으로 온도와 팬 속도를 실시간으로 보여 주고, 그래프로 그린 커브로 팬을 제어하고, 프리셋을 저장하고 바로 바꿀 수 있게 하면서 연산량을 거의 쓰지 않으려면 어떻게 구현해야 하는가.

Members + lanes: 8 + 4 · Waves: 2 (수집과 현지 실행 검증) · Sources: 60 · Verifications: 5 (현지 실행) · Debate rounds: 3

## 요약

M5 Pro에서도 팬 제어가 가능하다. 이 맥에서 root 권한으로 직접 값을 써서 확인했다 [V1]. 쓰기에 쓰는 키는 두 개다. `F{n}Tg`(목표 RPM, 4바이트 little-endian float)와 `F{n}md`(모드: 0=시스템, 1=수동). M1~M4에서 쓰던 잠금 해제 키 `Ftst`는 이 기종에 없고, 해제 절차도 필요 없다 [Source 5][Source 3][V1]. 실측 중 위험한 함정 하나가 드러났다. `md=1`은 그 시점에 래치된 `Tg`를 따르는데, `Tg`를 한 번도 쓴 적 없는 팬은 목표가 0이 되어 **멈춰 버린다** [V1]. 그래서 쓰기 순서는 항상 `Tg` 먼저, `md=1` 나중이다.

쓰기에는 root 권한이 필요하고 읽기는 일반 사용자 권한으로도 가능하다 [V2]. 개발자 ID 없이 직접 빌드한 앱은 SMAppService 데몬을 쓸 수 없다. macOS 27 SDK 헤더가 LaunchDaemon을 포함한 앱에 공증을 요구하기 때문이다 [A4][Source 43]. 남은 방법은 `/Library/LaunchDaemons`에 레거시 데몬을 두는 것이다. 같은 헤더에는 이 방식이 별도 승인 없이 부팅 시 실행된다고 적혀 있다. 설치할 때 관리자 암호를 한 번만 묻는다.

오버헤드를 좌우하는 건 SMC 읽기가 아니라 UI를 다시 그리는 일이다. SMC를 한 번 읽을 때 드는 CPU 시간은 약 10µs다(벽시계 시간은 약 110µs) [V3]. AppKit `NSStatusItem` 앱에서 제목을 값이 바뀔 때만 갱신했더니 phys_footprint는 13MB, CPU 사용률은 0.0%로 측정됐다 [A6]. 매 틱 갱신하면 0.2~3.9% 스파이크가 생겼다. SwiftUI MenuBarExtra는 메모리를 약 5MB 더 쓰고 스파이크도 더 컸다 [A6][Source 22][Source 23].

## 1. SMC 프로토콜 (현지 검증 완료)

| 항목 | 값 | 근거 |
|---|---|---|
| 서비스 | `IOServiceMatching("AppleSMC")`, `IOServiceOpen` type 0 | [Source 3][Source 7][Source 14] |
| 호출 | `IOConnectCallStructMethod(conn, 2, …)`, 80바이트 `SMCKeyData` | 로컬 `MemoryLayout` = 80 [V2], fand의 컴파일 타임 assert [Source 7] |
| 명령 | data8 9=keyInfo, 5=read, 6=write, 8=index | [Source 7][Source 8] |
| 성공 판정 | `kern_return == 0` **그리고** 결과 바이트 `== 0x00` | [Source 3][Source 8] |
| 권한 | 읽기는 uid 501로 가능, 쓰기는 `0xe00002c1`(kIOReturnNotPrivileged) | [V2] |
| 쓰기 가능 키 | W 비트가 있는 키는 `F0md`(attr 0xd0)와 `F0Tg`(0xd4)뿐. Mn/Mx/Dc/St는 읽기 전용 | [V4] |
| 인코딩 | `flt ` = 4B LE IEEE754, `ui8` 1B, `ui16/ui32` big-endian | [Source 8][Source 3][V2] |

수동 제어 순서 (Mac17,9 실측 [V1]):
1. `F{n}Tg = clamp(rpm, Mn, Mx)`를 쓴다. md=0 상태에서도 값이 래치된다(readback에는 시스템 값이 보인다).
2. `F{n}md = 1`을 쓴다. 팬 속도가 래치된 Tg로 1~2초 안에 수렴한다 [V1].
3. 이후 목표를 바꿀 때는 `F{n}Tg`만 쓴다. 3200rpm을 목표로 1.8초 만에 ±10rpm 이내에 들어왔다 [V1].
4. 2초 뒤에 `F{n}Ac`로 확인한다. Tg readback은 약 250ms 늦게 반영되고, 멈춘 팬은 다시 도는 데 약 6초가 걸린다 [V1].
5. 해제는 `F{n}md = 0`. 250ms 안에 시스템 목표로 돌아가고, RPM은 약 3초 뒤 원래대로 돌아온다 [V1].

미해결 사항:
- 장시간 수동 유지 중 시스템이 제어권을 회수하는지. 22초 동안은 회수가 없었다 [V1]. 다른 기종에서는 제어권이 회수되었다는 보고가 있다 [Source 56].
- 부팅당 쓰기 한도가 약 100회라는 주장 [Source 12]. 출처가 하나뿐이고 반박도 약하다 [D2]. 다만 값이 바뀔 때만 쓰면 별도 비용 없이 피할 수 있으므로 설계에 반영한다.

## 2. 센서

| 용도 | 키 | 근거 |
|---|---|---|
| CPU (표시와 커브 입력) | super core `Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K`, performance core `Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y` 중 최댓값 | Stats의 M5 센서 표 [Source 53], 이 맥에 18개 모두 존재 [V5] |
| GPU | `Tg0U Tg0X Tg0d Tg0g Tg0j Tg1Y Tg1c` 중 최댓값 (`Tg1g`는 이 맥에 없음) | [Source 53][V5] |
| 팬 | `F{n}Ac`(실제 RPM), `F{n}Mn`/`F{n}Mx`(2317/7826), `FNum`=2 | [V1][V2] |
| 참고 (미채택) | `TPD*`/`TRD*`는 CPU 부하에 반응(+22.6°C), `TVD*`는 SoC 가상 다이 온도(부하 시 93.5°C) | 팀의 현지 측정 [A3] |

`TPD*`와 `TVD*`는 공식 이름이 없다. 그래서 Stats가 이름을 붙여 둔 `Tp*`/`Tg*`를 기본으로 쓴다. 한 틱에 읽는 키는 CPU 18, GPU 7, 배터리 3, 팬 6(팬마다 실제·목표·모드)으로 모두 34개이고, CPU 시간은 약 0.34ms다. 1Hz로 읽으면 단일 코어 사용률은 0.034%다(DERIVED: 34 × 10µs [V3]). 없는 키는 처음 한 번만 확인하고 그 뒤로는 읽지 않는다. 존재하지 않는 키를 읽으면 정상 키보다 약 50배 많은 비용이 들기 때문이다 [A6]. 0~130°C 범위를 벗어나거나 NaN인 값은 버린다 [Source 7].

## 3. 권한 헬퍼와 IPC

결정: 레거시 LaunchDaemon과 Unix 도메인 소켓을 쓰고, `getpeereid`로 uid를 검사한다.

- SMAppService.daemon은 쓰지 않는다. macOS 27 SDK `SMAppService.h`에 "Apps that contain LaunchDaemons must be notarized"라고 적혀 있다. 같은 헤더에 레거시 `/Library/LaunchDaemons`는 승인 없이 부팅된다는 문구도 있다 [A4]. 2026년 포럼에는 공증 없는 SMAppService 데몬이 AMFI -413으로 막혔다는 보고가 있고 [Source 43], macOS 27에서 일반 LaunchDaemon이 동작했다는 보고도 있다 [Source 44].
- 설치: 팝오버 아래쪽의 "Install Helper…"를 누르면 `osascript … with administrator privileges`로 관리자 암호를 한 번 묻는다. 헬퍼 바이너리는 `/Library/PrivilegedHelperTools/com.stevenahhh.openfan.helper`(root:wheel 0755), plist는 `/Library/LaunchDaemons/com.stevenahhh.openfan.helper.plist`(root:wheel 0644)에 놓고 `launchctl bootstrap system`으로 로드한다. 제거할 때는 `launchctl bootout system/com.stevenahhh.openfan.helper` 후 두 파일을 지운다 [A4][Source 39].
- 서명: 모든 바이너리는 ad-hoc(`codesign -s -`)으로 서명한다. 서명이 없으면 이 맥에서 실행 즉시 SIGKILL로 종료된다 [A4].
- IPC: 헬퍼가 `/var/run/com.stevenahhh.openfan.sock`을 만들고 권한을 0666으로 둔다. 대신 연결마다 `getpeereid`로 uid가 {0, 설치 사용자} 중 하나인지 확인하고, 그렇지 않으면 연결을 즉시 끊는다 [Source 32][Source 33][Source 46].
  - XPC 코드 서명 요구사항을 쓸 수도 있다. 하지만 ad-hoc 코드로는 빌드마다 바뀌는 cdhash나 위조할 수 있는 identifier만 지정할 수 있다 [Source 45][A2]. 자체 서명한 인증서로 안정적인 요구사항을 만들 수 있다는 것도 확인했다 [A4]. 다만 그러려면 키체인에 인증서를 따로 만들어야 한다. uid 검사는 서명 인프라 없이도 같은 수준의 경계를 제공한다. 같은 uid의 프로세스는 어차피 앱 자체를 조작할 수 있다. 게다가 헬퍼는 팬을 [Mn, Mx] 범위 밖으로 설정하지 않으므로, 오용되어도 최악의 경우 소음이 커지는 정도다.
- 프로토콜: 한 줄에 명령 하나를 보내는 텍스트 방식이다. `PING`, `STATUS`, `AUTO`, `CURVE <max|cpu|gpu|battery> t:p,…`, `FIXED <percent>`. `battery`는 TB0T/TB1T/TB2T 중 유효한 센서의 평균이다. NaN이나 범위 밖 숫자는 거부한다. 점은 2~12개여야 하고(ASSUMED: 편집기 조작성을 기준으로 함), 온도는 순증가(strictly increasing)해야 한다.

## 4. 제어 루프와 안전장치

| 항목 | 값 | 근거 / 계보 |
|---|---|---|
| 커브 평가 위치 | 헬퍼(root)에서 평가한다. 앱이 종료되어도 안전장치는 계속 동작한다 | [A5][Source 7] |
| 틱 | 제어 중에만 1초 주기로 동작한다. 대기 중에는 타이머 없이 소켓 연결만 기다린다 | fand는 0.5초, fanctl은 2초 [Source 7][Source 8]. 1초는 ASSUMED |
| 입력 | 프리셋마다 `cpu`/`gpu`/`max`/`battery` 중 하나를 고르며, 기본값은 `max`다 | [A5] 클래스별 최댓값 |
| 히스테리시스(하강) | 2°C | fand의 하강 폭은 3.0°C, fanpro는 2°C [Source 7][A5] |
| 쓰기 dead band | 목표 RPM이 100rpm 이상 바뀔 때만 `Tg`를 쓴다 | fanctl 150rpm [Source 8], 쓰기 한도 [Source 12] |
| 과열 | 커브 입력과 상관없이 CPU/GPU 중 가장 뜨거운 값이 95°C 이상이면 팬을 Mx로 설정하고, 88°C 미만으로 내려오면 해제한다 | fand >95°C [Source 7], fanctl ≥95°C [Source 8] |
| 회수 대응 | 틱마다 `F{n}md`를 읽어 1이 아니면 `Tg`를 먼저 쓰고 `md=1`을 다시 쓴다 | [Source 17][Source 56] |
| 리스 | 앱은 소켓 연결을 유지하고 커브를 적용하는 동안 틱마다(팝오버가 닫혀 있으면 3초, 열려 있으면 1초) PING을 보낸다. 연결이 끊기거나 12초 동안 신호가 없으면 auto로 전환한다 | fanfan 10초 리스 [Source 35], 9fan 6초 [Source 32] |
| 종료 | SIGTERM/SIGINT/SIGHUP을 받으면 모든 팬을 `md=0`으로 설정한 뒤 종료한다 | [Source 7][A2] |
| 시작 | 이전 인스턴스가 남긴 `md≠0` 상태를 0으로 되돌린다 | Aeolus의 부팅 시 정합 [Source 37] |
| 잠자기 | 잠들기 직전 auto로 전환하고, 깨어난 뒤 다음 틱에 다시 적용한다 | Stats [Source 40] |
| SMC 오류 | `0x82`가 반환되거나 쓰기에 실패하면 auto 전환을 시도하고, 감시 전용으로 바꾼 뒤 STATUS로 알린다 | [Source 12][A5] |
| 쓰기 순서 | 항상 `Tg` 먼저, `md=1` 나중. `Tg ≥ Mn`을 보장한다 | [V1] |

## 5. UI와 오버헤드

- AppKit `NSStatusItem`과 `NSPopover`를 쓰고 SwiftUI MenuBarExtra는 쓰지 않는다. 팝오버 하나에 실시간 값, 프리셋 칩, 커브 편집기, 메뉴바 텍스트 설정 페이지가 모두 들어 있고 별도 창은 없다. 측정상 메모리는 AppKit이 13MB, MenuBarExtra가 17~21MB였고, 갱신 스파이크도 AppKit 쪽이 작았다 [A6]. MenuBarExtra는 라벨이 템플릿 이미지로만 그려지고 생명주기 버그도 있다 [Source 26].
- 메뉴바 제목은 기본값 `{max}° {rpm}` 템플릿(`52° 2.3k`)으로 짧게 표시하고 사용자가 `{cpu}` `{gpu}` `{bat}` `{rpm0}` `{rpm1}` `{preset}`로 바꿀 수 있다(40자 제한, `settings.json`). 앞에 Activity Monitor와 같은 기준(`kern.memorystatus_vm_pressure_level` 1/2/4 → 초록/노랑/빨강)의 메모리 압력 점을 둘 수 있다. 제목과 점은 **문자열이 바뀔 때만** 새로 설정한다. 매 틱 설정하면 0.2~3.9%, 바뀔 때만 설정하면 0.0%였다 [A6][Source 22][Source 23].
- 계속 살아 있는 `DispatchSourceTimer` 하나를 쓴다. 팝오버가 닫혀 있으면 3초, 열려 있으면 1초 주기로 돈다. leeway는 주기의 20%로 설정해 Apple 권장치(10% 이상)를 지킨다 [Source 20]. 같은 상태 데이터를 다시 그리지 않는다.
- 커브 편집기는 Core Graphics로 직접 그리는 `NSView`이고, 팝오버를 열 때만 만들고 닫으면 해제한다. 매초 바뀌는 실시간 표시(점선, 점, 라벨)는 다시 그리지 않고 `CALayer` 속성만 바꾼다. 매초 `draw(_:)`로 다시 그리면 그래픽 백킹 스토어가 약 70MB 남았고, 레이어로 바꾼 뒤 열린 상태 28MB, 30번 열고 닫은 뒤 26MB였다(MEASURED). Swift Charts는 쓰지 않는다(시리즈 하나에 34~90MB) [A6].
- SMC 연결은 하나만 열어 두고, 키 정보는 처음 한 번만 캐시한다 [Source 25][A6].
- 읽기 작업은 `.utility` QoS로 실행하고 프로세스 assertion은 잡지 않는다. App Nap도 막지 않는다 [Source 28].
- 빌드 플래그는 `-O -wmo`와 `-dead_strip`이다. 바이너리 크기가 약 34% 줄어든다(MEASURED) [A6].
- 측정은 `footprint -p`(phys_footprint)와 `top -l N -s 1 -pid`로 한다. RSS에는 공유 프레임워크 약 35MB가 포함되므로 쓰지 않는다 [A6].

## 6. 커브와 프리셋 데이터 모델

- 커브는 구간별 선형(piecewise linear)이다. 점은 2~12개이고, x는 순증가, y는 감소하지 않는다. 첫 점보다 낮은 온도에는 첫 점의 값을, 마지막 점보다 높은 온도에는 마지막 점의 값을 쓴다 [Source 49][A7].
- y축은 `[Mn, Mx]`에 대한 퍼센트다. `rpm = Mn + p/100 × (Mx − Mn)`이고, Mac17,9에서는 `2317 + p × 55.09`다 [A7].
- 편집기 조작: 점을 끌어 옮기고, 빈 곳을 더블클릭하면 점을 추가하고, 점을 우클릭하면 삭제한다. 끌어 옮기는 동안 1°C/1% 단위로 스냅된다. 그래프 위에 현재 온도와 RPM이 점으로 표시된다 [Source 49][Source 50].
- 저장: `~/Library/Application Support/OpenFan/presets.json`에 `{ "version": 2, "active": "<id|auto>", "presets": [ { "id", "name", "input": "max|cpu|gpu|battery", "points": [[t, p], …] } ] }` 형태로 쓴다. "Auto"는 프리셋이 아니라 별도 모드이고, `md=0`이다 [A7 수정본]. **version 2는 사용자 프리셋만 저장한다**: 기본 프리셋은 코드가 소유하고 편집·이름 변경·삭제가 모두 거부된다. version 1 파일은 로드 시 이전된다(그대로인 기본 프리셋 사본은 버리고, 사용자가 고친 사본은 사용자 프리셋으로 옮기며 활성 선택이 그쪽을 따라간다).
- 0 %는 "최저 속도"가 아니라 **팬을 macOS로 돌려주는 것**이다: 커브가 0 %를 가리키면 컨트롤러는 그 팬을 릴리스(`md=0`)하고, 0 % 위로 올라오면 목표값을 먼저 쓴 뒤 다시 잡는다. 따라서 `Mn` 아래의 목표값은 결코 쓰지 않고, 시원한 맥에서는 macOS가 팬을 세운다. 95 °C 패닉 가드는 그대로 최고 속도를 강제한다.
- 메뉴바 템플릿은 빈 문자열도 유효하다(점만 표시). 사용자 프리셋이 하나도 없을 때 새 프리셋은 `30:0, 50:15, 70:45, 95:100`에서 시작한다.
- 헤더 팬 값은 기본적으로 팬 범위 대비 퍼센트다. 최저 속도(`Mn`)가 0 %, 최고 속도(`Mx`)가 100 %라서 커브의 세로축과 같은 숫자를 쓴다. 멈춘 팬도 0 %로 보인다. 팬 행을 클릭하면 RPM으로 바뀌며 그 선택은 `settings.json`에 남는다.
- 기본 프리셋(ASSUMED, A7 초안을 이 맥의 측정값에 맞게 조정함. 유휴 시 CPU는 약 50°C [V5]):

| 이름 | 점 (°C:%) |
|---|---|
| Silent | 30:0, 50:5, 70:15, 85:45, 95:100 |
| Balanced | 30:0, 45:5, 60:20, 75:45, 90:80, 95:100 |
| Performance | 30:0, 40:20, 55:40, 70:70, 85:100 |
| Full | 0:100, 130:100 |

세 기본 커브 모두 30 °C 이하에서 0 %(팬 정지, macOS에 위임)이고, Full은 커브가 아니라 전 구간 100 %다(편집기에서 "항상 최고 속도"라고 명시한다).

## 토론 기록

| 라운드 | 공격 | 판정 |
|---|---|---|
| D1 | "M5 Pro/macOS 27에서 임의 RPM 성공 사례가 0건이다"(skeptic, stats #3021/#3371, solofan #21) | 현지 root 프로브로 반박. 동작함 [V1]. 대신 md=1만 쓰면 팬이 멈추는 새 위험을 찾았다 |
| D2 | 부팅당 쓰기 100회 한도 [Source 12] | 약화. 출처가 하나이고 fand는 0.5초마다 써도 문제가 없었다. 값이 바뀔 때만 쓰는 설계로 대응 |
| D2 | "ad-hoc 서명이면 모든 SMC 호출이 거부된다" | 반박. 현지에서 ad-hoc 바이너리로 3611개 키를 읽었다 [V2] |
| D0 | "Stats의 팬 제어는 읽기 전용이다"(ux-curves) | 반박. Stats 코드에 쓰기 경로가 있다 [Source 3] |

## 공백

- 장시간(수십 분 이상) 수동 유지 중 회수 여부는 앱 QA에서 확인한다 [Source 56].
- 부팅당 쓰기 한도는 따로 검증하지 않았다. 설계상 쓰기 횟수가 매우 적다 [Source 12].
- `TUD*`, `TS0P`, `TW0P` 같은 센서의 정체는 모른다. 팬 제어에는 필요 없다.

## 만든 방법

- 1차 수집이 끝난 뒤 쟁점이 된 주장은 이 맥에서 직접 실행해 보고 판정했다. 비특권 쓰기, 읽기 비용, 키 속성, 센서 키 존재 여부, root 쓰기 프로브(관리자 암호 1회)가 그 대상이다.
- 토론은 3라운드였다. 실행 결과가 뒤집은 주장은 두 가지다. 하나는 "M5 Pro와 macOS 27에서는 임의 RPM이 안 된다"는 주장이고, 다른 하나는 "Tg는 읽기 전용이다"라는 fand의 결론이다. 반면 실행 과정에서 새로 발견한 사실도 있다. md=1만 쓰면 팬이 멈춘다.
- 조사 과정의 원본 기록(팀원별 보고, 출처 목록, 검증 로그)은 이 저장소에 포함하지 않는다.

## 검증 기록

- [V1] root 쓰기 프로브: Mac17,9 / macOS 27.0.1, 쓰기 9회(MEASURED)
- [V2] [Source 3]과 대조한 비특권 쓰기 검증: 쓰기 거부 `0xe00002c1`, ad-hoc 읽기 성공
- [V3] 읽기 비용 측정: 읽기 CPU 10µs / 벽시계 110µs
- [V4] 키 속성 측정: keyInfo attr 덤프
- [V5] Stats가 쓰는 M5 센서 키가 이 맥에 있는지 확인
- [A2]~[A7]: 조사 중 팀원별 보고서(A3, A4, A6에는 현지 실험이 포함됨). 이 저장소에는 포함하지 않는다

## Sources

번호는 조사 중 작성한 출처 목록을 따르며, 이 저장소에는 주요 출처만 싣는다. 주요 출처:
- [Source 3] https://github.com/exelban/stats/blob/e27b499f42ad5117777a11a3c6b29b7f0f4ae758/SMC/smc.swift
- [Source 5] https://github.com/exelban/stats/commit/fb95e33cb6
- [Source 7] https://github.com/yolo-labz/fand/tree/a9930b516fe1898f607529610876912538e35097
- [Source 8] https://github.com/erogol/fanctl/tree/c61f310444326bec1e4e644bbc09403a1513c487
- [Source 12] https://github.com/alfaiotadev/apple-silicon-smc-fan-write-limit
- [Source 14] https://github.com/beltex/SMCKit/tree/afb7147e32c9d37e962abab0140064cf33b9c68f
- [Source 17] https://github.com/raminsharifi/MacFanControl
- [Source 19] https://crystalidea.com/macs-fan-control/release-notes
- [Source 20] https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html
- [Source 22] https://github.com/robinebers/openusage/issues/1039
- [Source 23] https://github.com/m1ckc3s/claude-status-bar/issues/53
- [Source 25] https://github.com/exelban/stats/issues/3485
- [Source 26] https://akring.com/blog/a-strange-bug-caused-by-swiftui-macos-26/
- [Source 28] https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html
- [Source 32] https://github.com/syncroot/9fan/blob/9215e742c759aa288e123ad11925a7f224e2515d/src/channel.c
- [Source 33] https://github.com/estevecastells/macfanoptimizer/blob/48bf77030c62db5e7be2819aa31a2cfaba4b0b7c/crates/fand/src/smc_hw.rs
- [Source 35] https://github.com/hoobnn/fanfan/blob/ae0bb9cf61c9a9793ca69b11c9194e49564d60db/tools/fanfan-smcd/fanfan-smcd.c
- [Source 37] https://github.com/blamechris/Aeolus/blob/0166ccdc3127e50997f4405446741bda998ab6f3/Configs/LaunchDaemons/com.blamechris.Aeolus.Helper.plist
- [Source 39] https://github.com/askender/fansctl/tree/b25947113f907a2075bc2070a2e055204d4d333d
- [Source 40] https://github.com/exelban/stats/blob/e27b499f42ad5117777a11a3c6b29b7f0f4ae758/Modules/Sensors/popup.swift
- [Source 43] https://developer.apple.com/forums/thread/843622
- [Source 44] https://developer.apple.com/forums/thread/848726
- [Source 45] https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- [Source 46] https://github.com/apple-oss-distributions/xnu/blob/8d741a5de7ff4191bf97d57b9f54c2f6d4a15585/bsd/sys/un.h
- [Source 49] https://getfancontrol.com/docs/
- [Source 50] https://github.com/agoodkind/macos-fan-curve
- [Source 53] https://github.com/exelban/stats/blob/e27b499f42ad5117777a11a3c6b29b7f0f4ae758/Modules/Sensors/values.swift#L488-L515
- [Source 55] https://www.tunabellysoftware.com/tgpro/releasenotes/
- [Source 56] https://github.com/exelban/stats/issues/3371
