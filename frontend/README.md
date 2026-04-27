# Furni3D

가구 사진 한 장으로 3D 모델을 만들어주는 Flutter 앱.

---

## 사전 준비

### Flutter 설치 (처음 한 번만)

```bash
brew install --cask flutter
```

### `.config` 권한 문제 해결 (처음 한 번만)

macOS에서 `/Users/<username>/.config` 가 root 소유인 경우 아래를 실행:

```bash
mkdir -p ~/.flutter_config
```

그리고 `~/.zshrc` 에 추가:

```bash
export XDG_CONFIG_HOME=~/.flutter_config
```

이후 터미널 재시작 또는:

```bash
source ~/.zshrc
```

---

## 실행 방법

### 1. 의존성 설치

```bash
cd ~/Desktop/Furni3D
flutter pub get
```

### 2. 연결된 기기 확인

```bash
flutter devices
```

시뮬레이터나 실제 기기가 목록에 나와야 합니다.

### 3. 앱 실행

```bash
flutter run
```

특정 기기를 지정하려면:

```bash
flutter run -d <device-id>
```

---

## 코드 수정 → 즉시 반영

앱이 실행 중인 터미널에서:

| 키 | 동작 | 언제 사용 |
|---|---|---|
| `r` | Hot reload | UI, 스타일 변경 시 (앱 상태 유지) |
| `R` | Hot restart | 로직, 상태 초기화가 필요할 때 |
| `q` | 종료 | — |

VS Code / Android Studio에서는 파일 저장 시 자동으로 hot reload됩니다.

---

## 앱 흐름

```
홈 화면
 └── 사진으로 3D 만들기
      └── 갤러리에서 사진 선택
           └── AI 분석 완료 확인
                └── [3D로 변환하기] 탭
                     └── AI 처리 중 (4단계 시뮬레이션, ~9초)
                          └── 3D 모델 결과
                               └── [내 컬렉션에 저장하기] 탭
 └── 내 컬렉션
      └── 저장된 모델 그리드
```

---

## 프로젝트 구조

```
lib/
├── main.dart                  # 앱 진입점
├── app.dart                   # MaterialApp 설정
├── theme/
│   └── app_theme.dart         # 컬러 팔레트 & 테마
├── models/
│   └── furniture_model.dart   # 데이터 모델
├── providers/
│   └── collection_provider.dart  # SharedPreferences 저장소
└── screens/
    ├── home_screen.dart
    ├── upload_screen.dart
    ├── processing_screen.dart
    ├── result_screen.dart
    └── gallery_screen.dart
```

---

## 주요 패키지

| 패키지 | 용도 |
|---|---|
| `image_picker` | 갤러리 사진 선택 |
| `google_fonts` | Nunito 폰트 |
| `provider` | 상태 관리 |
| `shared_preferences` | 로컬 컬렉션 저장 |
| `gap` | 간격 위젯 |
| `uuid` | 모델 고유 ID 생성 |

---

## 참고

- 현재 3D 변환은 시뮬레이션입니다. 실제 AI 연동 시 `processing_screen.dart`의 `_buildModel()` 메서드를 API 호출로 교체하면 됩니다.
- iOS 실기기 테스트 시 Xcode에서 개발자 서명 설정 필요.
