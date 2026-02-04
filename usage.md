# py_webdav_stress_test.py 사용 설명서

이 문서는 `py_webdav_stress_test.py` 스크립트를 사용하여 WebDAV 서버에 대한 HEAD 요청 스트레스 테스트를 수행하는 방법을 설명합니다.

## 개요

이 스크립트는 Python의 `aiohttp` 라이브러리를 사용하여 지정된 WebDAV 서버에 대량의 HEAD 요청을 비동기적으로 보내 서버의 성능을 테스트합니다.

## 사전 요구사항

스크립트를 실행하려면 `aiohttp` 라이브러리가 필요합니다. 다음 명령어로 설치할 수 있습니다.

```bash
pip install aiohttp
```

## 사용법

스크립트는 커맨드 라인에서 인자를 전달하여 실행합니다.

```bash
python py_webdav_stress_test.py --target_base_url <서버 URL> --username <사용자 이름> --password <비밀번호> [옵션]
```

### 사용 예시

```bash
python py_webdav_stress_test.py --target_base_url http://192.168.1.100 --username testuser --password testpassword --request_count 100000 --concurrency 50
```

## 인자 (Arguments)

| 인자                  | 설명                                                                 | 기본값                               | 필수 여부 |
| --------------------- | -------------------------------------------------------------------- | ------------------------------------ | --------- |
| `--target_base_url`   | 테스트할 WebDAV 서버의 기본 URL (예: `http://localhost:8000`)        | 없음                                 | 예        |
| `--username`          | WebDAV 서버 인증에 사용할 사용자 이름                                | 없음                                 | 예        |
| `--password`          | WebDAV 서버 인증에 사용할 비밀번호                                   | 없음                                 | 예        |
| `--request_count`     | 보낼 총 HEAD 요청 횟수                                               | 200000                               | 아니요    |
| `--concurrency`       | 동시에 보낼 요청 수                                                  | 100                                  | 아니요    |
| `--user_agent`        | 요청에 사용할 커스텀 User-Agent 문자열                               | "WebDAV-Stress-Tester/1.0 (Python-aiohttp)" | 아니요    |
