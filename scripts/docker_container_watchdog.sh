#!/bin/bash
# 설치 스크립트 버전: v2.1
# 이 스크립트는 Debian에서 Docker 컨테이너(worker)를 감시하여
# 중단될 경우 자동으로 재시작하도록 supervisord와 watchdog 스크립트를 설정합니다.

# 버전 정보 변수
VERSION="v2.1"

echo "설치 스크립트 버전: ${VERSION}"

# 루트 권한 확인
if [ "$EUID" -ne 0 ]; then
  echo "이 스크립트는 root 권한으로 실행해야 합니다. sudo를 사용해 실행해 주세요."
  exit 1
fi

# 패키지 업데이트
echo "패키지 목록 업데이트 중..."
apt update

# supervisor 설치 (미설치 시)
if ! command -v supervisorctl &> /dev/null; then
  echo "supervisor 설치 중..."
  apt install -y supervisor
else
  echo "supervisor가 이미 설치되어 있습니다."
fi

# Docker 컨테이너 watchdog 스크립트 작성
WATCHDOG_SCRIPT="/usr/local/bin/docker_container_watchdog.sh"
echo "watchdog 스크립트를 ${WATCHDOG_SCRIPT} 에 생성합니다..."
cat << 'EOF' > ${WATCHDOG_SCRIPT}
#!/bin/bash

# 감시할 컨테이너 이름 설정 (예: worker)
CONTAINER_NAME="worker"

# 로그 파일 경로 (필요에 따라 변경)
LOGFILE="/var/log/docker_container_watchdog.log"

# 컨테이너 재시작 전 대기 시간 (초)
RESTART_DELAY=10

# 상태 점검 주기 (초)
INTERVAL=5

# 네트워크 에러 감지 관련 변수
NETWORK_ERROR_COUNT=0
NETWORK_ERROR_THRESHOLD=5  # 연속 네트워크 에러 횟수가 이 수치 이상이면 재부팅 시도

while true; do
    # 컨테이너 실행 상태 확인
    RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)

    if [ "$RUNNING" != "true" ]; then
        echo "$(date): 컨테이너 '$CONTAINER_NAME'가 실행 중이 아닙니다. 재시작 시도합니다..." >> "$LOGFILE"
        sleep "$RESTART_DELAY"
        docker start "$CONTAINER_NAME"
        if [ $? -eq 0 ]; then
            echo "$(date): 컨테이너 '$CONTAINER_NAME' 재시작 성공." >> "$LOGFILE"
        else
            echo "$(date): 컨테이너 '$CONTAINER_NAME' 재시작 실패." >> "$LOGFILE"
        fi
        # 컨테이너가 꺼져있는 경우 네트워크 에러 카운트 초기화
        NETWORK_ERROR_COUNT=0
    else
        # 컨테이너가 실행 중이면 최근 로그에서 "NetworkError"를 확인합니다.
        ERROR_COUNT=$(docker logs --tail 100 "$CONTAINER_NAME" 2>&1 | grep -c "NetworkError")

        if [ "$ERROR_COUNT" -gt 0 ]; then
            NETWORK_ERROR_COUNT=$((NETWORK_ERROR_COUNT + 1))
            echo "$(date): 네트워크 에러 감지. 현재 에러 카운트: $NETWORK_ERROR_COUNT" >> "$LOGFILE"
        else
            # 네트워크 에러가 없으면 카운트 리셋
            NETWORK_ERROR_COUNT=0
        fi

        # 연속 네트워크 에러 횟수가 임계치 이상이면 시스템 재부팅 시도
        if [ "$NETWORK_ERROR_COUNT" -ge "$NETWORK_ERROR_THRESHOLD" ]; then
            echo "$(date): 네트워크 에러가 지속되어 시스템 재부팅을 시도합니다." >> "$LOGFILE"
            sudo reboot
        fi
    fi
    sleep "$INTERVAL"
done
EOF

# watchdog 스크립트 실행 권한 부여
chmod +x ${WATCHDOG_SCRIPT}

# supervisord 설정 파일 작성 (감시 스크립트를 supervisord에서 관리)
SUPERVISOR_CONF="/etc/supervisor/conf.d/docker_container_watchdog.conf"
echo "Supervisor 설정 파일을 ${SUPERVISOR_CONF} 에 생성합니다..."
cat << 'EOF' > ${SUPERVISOR_CONF}
[program:docker_container_watchdog]
command=/usr/local/bin/docker_container_watchdog.sh
autostart=true
autorestart=true
startsecs=10
stdout_logfile=/var/log/supervisor/docker_container_watchdog_stdout.log
stderr_logfile=/var/log/supervisor/docker_container_watchdog_stderr.log
user=root
EOF

# supervisord 설정 재로딩
echo "Supervisor 설정을 재로딩합니다..."
supervisorctl reread
supervisorctl update

echo "설치 및 설정 완료! (버전: ${VERSION})"
echo "컨테이너 감시 로그: tail -f /var/log/docker_container_watchdog.log"
echo "supervisord 로그: tail -f /var/log/supervisor/docker_container_watchdog_stdout.log"
