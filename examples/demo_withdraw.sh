#!/usr/bin/env bash
# 快照撤回端到端示例：
#   发布 -> 撤回（返回快照标识/首次撤回时间/状态）-> 任意令牌 403 且不计数 ->
#   重复撤回返回首次结果 -> 同记录其他版本不受影响 -> 该版本发布/申请/批准均 409 ->
#   待审申请仍可驳回 -> 维护侧可见撤回时间与原因，公开侧不透露
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
ALICE_PW="${ALICE_PW:-alice-pw}"   # operator（申请人）
BOB_PW="${BOB_PW:-bob-pw}"         # reviewer（复核人）
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

step "0. 健康检查"
curl -sS "${BASE_URL}/healthz" | jq .

step "1. 创建记录并直接发布版本 1（上限 5 次；同一快照再签一支不限次令牌）"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
RECORD_ID=$(echo "${CREATE}" | jq -r .record_id)
PUB=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 5}')
SNAPSHOT_ID=$(echo "${PUB}" | jq -r .snapshot_id)
TOKEN=$(echo "${PUB}" | jq -r .token)
TOKEN2=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1}' | jq -r .token)
echo "snapshot=${SNAPSHOT_ID}"
printf '撤回前读取: HTTP %s\n' "$(code "${BASE_URL}/public/snapshots/${SNAPSHOT_ID}?token=${TOKEN}")"

step "2. 缺密钥/错密钥撤回 -> 401；未知快照 -> 404"
printf '缺密钥: HTTP %s\n' "$(code -X POST "${BASE_URL}/snapshots/${SNAPSHOT_ID}/withdraw" \
  -H 'Content-Type: application/json' -d '{"reason":"x"}')"
printf '未知快照: HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/snapshots/00000000-0000-0000-0000-000000000000/withdraw" \
  "${AUTH[@]}" -d '{"reason":"x"}')"

step "3. 凭服务密钥撤回快照（提交快照标识与撤回原因）"
curl -sS -X POST "${BASE_URL}/snapshots/${SNAPSHOT_ID}/withdraw" "${AUTH[@]}" \
  -d '{"reason": "发现未脱敏的身份证号，依法撤回"}' | jq .
# => {"snapshot_id":"...","status":"withdrawn","withdrawn_at":"...","reason":"...",...}

step "4. 撤回后：无论持哪枚令牌，公开读取一律 403 snapshot unavailable，且不消耗次数"
printf '令牌1: HTTP %s；令牌2: HTTP %s；伪造令牌: HTTP %s\n' \
  "$(code "${BASE_URL}/public/snapshots/${SNAPSHOT_ID}?token=${TOKEN}")" \
  "$(code "${BASE_URL}/public/snapshots/${SNAPSHOT_ID}?token=${TOKEN2}")" \
  "$(code "${BASE_URL}/public/snapshots/${SNAPSHOT_ID}?token=forged")"
echo "令牌1 计数（撤回前已用 1 次，撤回后不再增长）:"
curl -sS "${BASE_URL}/tokens/${TOKEN}" "${AUTH[@]}" | jq '{max_reads, reads_used, remaining_reads}'

step "5. 重复撤回（即使原因不同）返回首次结果"
curl -sS -X POST "${BASE_URL}/snapshots/${SNAPSHOT_ID}/withdraw" "${AUTH[@]}" \
  -d '{"reason": "第二次提交的不同原因"}' | jq '{snapshot_id, status, reason, withdrawn_at}'

step "6. 维护侧记录状态显示撤回时间、原因与状态（公开侧不透露原因）"
curl -sS "${BASE_URL}/records/${RECORD_ID}" "${AUTH[@]}" | jq '.snapshots'

step "7. 该版本再次直接发布 -> 409；修订出的新版本不受影响"
printf '再次发布版本 1: HTTP %s\n' "$(code -X POST "${BASE_URL}/records/${RECORD_ID}/publish" \
  "${AUTH[@]}" -d '{"version": 1}')"
curl -sS -X PUT "${BASE_URL}/records/${RECORD_ID}" "${AUTH[@]}" -d '{
  "base_version": 1,
  "text": "完全不同的新原文，敏感词ABC。",
  "intervals": [{"start": 9, "end": 15}]
}' | jq .
PUB2=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" -d '{"version": 2}')
SID2=$(echo "${PUB2}" | jq -r .snapshot_id)
TOK2=$(echo "${PUB2}" | jq -r .token)
printf '版本 2 快照读取: HTTP %s（同记录其他版本继续可读）\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID2}?token=${TOK2}")"

step "8. 受控流程：撤回版本的申请与批准 -> 409；待审申请仍可驳回"
CTRL=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "受控记录原文，机密编号SECRET-1。",
  "intervals": [{"start": 11, "end": 19}]
}')
CRID=$(echo "${CTRL}" | jq -r .record_id)
curl -sS -X PUT "${BASE_URL}/records/${CRID}/controlled" "${AUTH[@]}" | jq .
REQ_A=$(curl -sS -X POST "${BASE_URL}/records/${CRID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' -d '{"version": 1}' | jq -r .request_id)
APPROVE=$(curl -sS -X POST "${BASE_URL}/publish-requests/${REQ_A}/approve" -u "bob:${BOB_PW}")
CSID=$(echo "${APPROVE}" | jq -r .snapshot_id)
REQ_B=$(curl -sS -X POST "${BASE_URL}/records/${CRID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' -d '{"version": 1}' | jq -r .request_id)
curl -sS -X POST "${BASE_URL}/snapshots/${CSID}/withdraw" "${AUTH[@]}" \
  -d '{"reason": "复核后发现脱敏不充分"}' | jq '{snapshot_id, status, withdrawn_at}'
printf '撤回后再提交该版本申请: HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/records/${CRID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' -d '{"version": 1}')"
printf '批准既有待审申请: HTTP %s\n' "$(code -X POST \
  "${BASE_URL}/publish-requests/${REQ_B}/approve" -u "bob:${BOB_PW}")"
echo "待审申请仍可驳回:"
curl -sS -X POST "${BASE_URL}/publish-requests/${REQ_B}/reject" \
  -u "bob:${BOB_PW}" -H 'Content-Type: application/json' -d '{"reason":"版本已撤回"}' \
  | jq '{status, reviewed_by, reason}'
echo "已批准申请记录仍留存:"
curl -sS "${BASE_URL}/publish-requests/${REQ_A}" -u "alice:${ALICE_PW}" \
  | jq '{status, snapshot_id}'

printf '\n\033[1m快照撤回演示完成。\033[0m\n'
