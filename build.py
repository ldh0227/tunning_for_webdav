import PyInstaller.__main__
import os

# 빌드할 스크립트 파일명
script_file = 'py_webdav_stress_test.py'

# 생성될 실행 파일명 (확장자 제외)
executable_name = 'WebDAV_Stress_Tester'

# PyInstaller 인자 설정
# --onefile: 단일 실행 파일로 만듭니다.
# --clean: 빌드 전 이전 빌드 파일들을 정리합니다.
# --name: 생성될 실행 파일의 이름을 지정합니다.
# --noconsole: 실행 시 콘솔 창을 띄우지 않으려면 이 옵션을 추가합니다. (하지만 이 스크립트는 콘솔 출력이 중요하므로 사용하지 않습니다.)
pyinstaller_args = [
    '--name=%s' % executable_name,
    '--onefile',
    '--clean',
    os.path.join(os.getcwd(), script_file),
]

print(f"PyInstaller를 사용하여 '{script_file}'를 빌드합니다...")
print(f"명령어: pyinstaller {' '.join(pyinstaller_args)}")

try:
    PyInstaller.__main__.run(pyinstaller_args)
    print("\n" + "="*50)
    print(f"빌드가 성공적으로 완료되었습니다!")
    print(f"결과물은 'dist/{executable_name}.exe' 파일로 저장되었습니다.")
    print("="*50)
except Exception as e:
    print("\n" + "!"*50)
    print(f"빌드 중 오류가 발생했습니다: {e}")
    print("!"*50)

