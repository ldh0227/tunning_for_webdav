# WebDAV All-in-One Setup Tasks

`setup_webdav_all-in-one.ps1` 스크립트가 수행하는 전체 작업 항목입니다.

1. **IIS 서비스 기능 추가 설치**
   - Web Server, Web Management Console, WebDAV Publishing 등 기본 역할
   - **Basic Authentication (`Web-Basic-Auth`) 추가 설치**
   - **URL Authorization (`Web-Url-Auth`) 추가 설치**

2. **증거서버 관리자(epoadmin) 계정 설정**
   - `epoadmin` 로컬 계정 생성
   - **`epoadmin` 계정을 관리자 그룹(`Administrators`)에 추가**

3. **IIS Default Web Site 셋팅 (연결 계정 생성 및 연결 테스트)**
   - Default Web Site의 물리적 경로 자격 증명(Connect As)으로 `epoadmin` 지정 및 패스워드 설정

4. **증거파일 저장 폴더 공유 설정 및 권한 부여**
   - 물리적 경로 폴더 생성 및 NTFS 권한 부여
   - **고급 공유 사용자 추가 (SMB Share) 및 `epoadmin`에 전체(읽기/쓰기) 권한 부여**

5. **가상디렉터리 셋팅 (연결 계정 생성 및 연결 테스트)**
   - `evidence` 가상 디렉터리 생성
   - **가상 디렉터리의 물리적 경로 자격 증명(Connect As)으로 `epoadmin` 지정 및 패스워드 설정**

6. **Default Web Site 인증 설정**
   - **익명 인증(Anonymous), ASP.NET 감지 인증 비활성화**
   - **윈도우 인증(Windows), 기본 인증(Basic) 활성화**

7. **Directory Browsing 활성화**
   - Default Web Site 및 가상 디렉터리 수준에서 디렉터리 검색(Directory Browsing) 활성화

8. **WebDAV 제작 규칙 추가 및 활성화**
   - WebDAV Authoring 활성화
   - **모든 컨텐츠 대상, 모든 사용자(`*`)에게 읽기(Read), 원본(Source), 쓰기(Write) 권한 부여**

---
*참고: 위 내용은 요청하신 1~8번 항목을 포함하여 스크립트에 모두 반영/정리된 기준입니다.*
