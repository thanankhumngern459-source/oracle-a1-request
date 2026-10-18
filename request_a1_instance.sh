#!/usr/bin/env bash
# ============================================================
# request_a1_instance.sh
# ------------------------------------------------------------
# ขอเครื่อง Always Free (VM.Standard.A1.Flex, ARM) ซ้ำๆ จนกว่า Oracle
# จะมีที่ว่าง — แก้ปัญหา "Out of host capacity" ตอนกดสร้างในหน้าเว็บ
#
# วิธีใช้ — เลือกได้ 2 แบบ:
#   ก) GitHub Actions (ทำงานแม้ปิดโน้ตบุ๊ก): ดู .github/workflows/request-a1.yml
#      workflow จะตั้งค่า ~/.oci/config จาก GitHub Secrets แล้วรันไฟล์นี้ทุก 5 นาที
#      ด้วย ROUNDS=1 (ลองครบทุก AD 1 รอบแล้วจบ รอรอบถัดไปใน 5 นาที)
#   ข) Oracle Cloud Shell (ต้องเปิดหน้าเว็บค้างไว้): อัปโหลดไฟล์นี้แล้วรัน
#      bash request_a1_instance.sh   (ไม่ตั้ง ROUNDS = ลองไปเรื่อยๆ จนได้)
#
# ความปลอดภัยของสคริปต์:
#   - ถ้ามีเครื่องชื่อ $INSTANCE_NAME อยู่แล้ว จะหยุดทันที (กันสร้างซ้ำ/เกินโควตาฟรี)
#   - ได้เครื่องแล้วหยุดเอง ไม่ลองต่อ
#   - เว้นระยะทุกครั้งที่ลอง และถอยห่างขึ้นเมื่อโดน Oracle จำกัดความถี่ (429)
#   - รันซ้ำได้เสมอ ถ้า Cloud Shell หลุดก็แค่รันใหม่
# ============================================================
set -u

# ---------- ค่าที่ปรับได้ ----------
INSTANCE_NAME="homeward-server"
OCPUS=2            # Always Free รวมทุกเครื่องได้ไม่เกิน 4 OCPU
MEMORY_GB=12       # Always Free รวมทุกเครื่องได้ไม่เกิน 24 GB
BOOT_GB=50         # Always Free รวม Block Volume ทั้งหมดได้ไม่เกิน 200 GB
SUBNET_NAME="public subnet-homeward-vcn"
RETRY_SECONDS=60   # เว้นระยะระหว่างแต่ละรอบ (อย่าตั้งต่ำกว่านี้ จะโดน 429 บ่อย)
SHAPE="VM.Standard.A1.Flex"
ROUNDS="${ROUNDS:-0}"   # จำนวนรอบที่ลองก่อนจบ (0 = ไม่จำกัด) — GitHub Actions ตั้งเป็น 4
# กุญแจสาธารณะจาก C:\nginx-1.31.7\key_oeacle_cloud\ssh-key-2026-10-13.key.pub
# (ใช้คู่กับไฟล์ .key ไฟล์เดียวกันตอน SSH เข้าเครื่อง)
SSH_PUBLIC_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDUlem1HJ9QFMh2HeGg1P2j1R9BTbAwxdzjhJ8dGopt+bsuSUqk6AIVoQZ0btMFwjPh4M4ApQ4egevhyGoo+OcY3UsBFNs2TAgDmJWU38QmHrKyL893iQqP43r2eos+Zjo+9cDzTL1gP+qeqxZ8rnQpm5K8lqHs+Dyutfy6hkwOnvYI0dFl+xXdeClaAQskWBj+zodFLHP1oT/50x1/rcvegeEntiVjg8Dpq+cS66ldnZbrrq6qphq61yz7zFnFk15HSV2hljr7QVsE3AM5oz4GA+VxogHKW4UQ6bZJCTV4BM2zgm8J7nBDqcxZIEgWRsmS7+B569nmpYwAXtBnNVrL ssh-key-2026-10-13'

log() { echo "[$(TZ=Asia/Bangkok date '+%Y-%m-%d %H:%M:%S')] $*"; }

# บน GitHub Actions เขียนผลลัพธ์สำคัญลงหน้าสรุปของ run ด้วย จะได้เห็นทันทีโดยไม่ต้องเปิด log
summary() {
  log "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# repo บน GitHub เป็น Public — log ของ Actions ทุกคนเปิดดูได้ จึงห้ามพิมพ์ OCID
# หรือ Public IP ของเซิร์ฟเวอร์ลง log (ให้ไปดูใน Oracle Console แทน)
# ส่วนใน Cloud Shell เห็นแค่เจ้าของบัญชี แสดงได้ตามปกติ
reveal() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "(ซ่อนไว้ ดูใน Oracle Console)"
  else
    echo "$1"
  fi
}

# แสดงข้อความ error จาก Oracle เพื่อหาสาเหตุ แต่บน GitHub ปิด OCID/IP ทุกตัวก่อนพิมพ์
show_error() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "$1" | sed -E 's/ocid1\.[A-Za-z0-9._-]+/ocid1.***/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/x.x.x.x/g'
  else
    echo "$1"
  fi
}

# ---------- ตรวจสภาพแวดล้อม ----------
if ! command -v oci >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  log "ไม่พบคำสั่ง oci หรือ jq — สคริปต์นี้ออกแบบให้รันใน Oracle Cloud Shell"
  exit 1
fi

# Cloud Shell ตั้งค่า OCI_TENANCY ไว้ให้เสมอ ส่วน GitHub Actions ส่งมาจาก Secret
# ใช้ root compartment ของบัญชี
# ตัดช่องว่าง/ขึ้นบรรทัดที่อาจติดมาตอนคัดลอกค่าใส่ Secret (ติดมาแล้ว Oracle จะตอบ 404)
COMPARTMENT_ID=$(printf '%s' "${OCI_TENANCY:-}" | tr -d '[:space:]')
if [ -z "$COMPARTMENT_ID" ]; then
  log "ไม่พบ OCI_TENANCY — รันใน Oracle Cloud Shell หรือตั้ง Secret OCI_TENANCY ใน GitHub"
  exit 1
fi
# กันใส่ค่าสลับช่อง (เช่นเอา user OCID มาใส่ OCI_TENANCY) — บอกแค่ "ชนิด" ของ OCID ไม่แสดงค่าจริง
case "$COMPARTMENT_ID" in
  ocid1.tenancy.*) ;;
  *)
    summary "OCI_TENANCY ไม่ใช่ tenancy OCID (ได้ชนิด: $(printf '%s' "$COMPARTMENT_ID" | cut -d. -f1-2)) — ต้องเป็นค่าหลัง tenancy= ที่ขึ้นต้นด้วย ocid1.tenancy."
    exit 1
    ;;
esac

# ---------- ทดสอบการเชื่อมต่อก่อน (Secrets ผิดจะรู้ตรงนี้ พร้อมข้อความจาก Oracle) ----------
if ! ad_json=$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" 2>&1); then
  summary "เชื่อมต่อ Oracle ไม่ได้ — ตรวจ Secrets (OCI_USER/OCI_TENANCY/OCI_FINGERPRINT/OCI_REGION/OCI_KEY)"
  show_error "$ad_json"
  exit 1
fi
mapfile -t ADS < <(echo "$ad_json" | jq -r '.data[].name')
if [ "${#ADS[@]}" -eq 0 ]; then
  log "ไม่พบ Availability Domain"
  exit 1
fi
log "เชื่อมต่อ Oracle สำเร็จ (${#ADS[@]} Availability Domain)"

# ---------- กันสร้างซ้ำ ----------
if ! existing_json=$(oci compute instance list --compartment-id "$COMPARTMENT_ID" --all 2>&1); then
  log "อ่านรายการเครื่องไม่ได้"
  show_error "$existing_json"
  exit 1
fi
[ -z "$existing_json" ] && existing_json='{"data":[]}'
existing_id=$(echo "$existing_json" | jq -r --arg name "$INSTANCE_NAME" \
  '[.data[]? | select(."display-name" == $name and ."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")][0].id // empty')
if [ -n "$existing_id" ]; then
  existing_ip=$(oci compute instance list-vnics --instance-id "$existing_id" 2>/dev/null | jq -r '.data[0]."public-ip" // empty')
  summary "มีเครื่องชื่อ $INSTANCE_NAME อยู่แล้ว — ไม่สร้างซ้ำ (Public IP: $(reveal "${existing_ip:-ยังไม่มี}")) ปิด workflow นี้ได้แล้ว"
  exit 0
fi

# รวม OCPU/RAM ของเครื่อง A1 ที่มีอยู่ กันขอเกินโควตาฟรี (เกินแล้วอาจโดนคิดเงินถ้าเป็น Pay As You Go)
used_ocpus=$(echo "$existing_json" | jq --arg shape "$SHAPE" \
  '[.data[]? | select(.shape == $shape and ."lifecycle-state" != "TERMINATED") | ."shape-config".ocpus] | add // 0')
used_mem=$(echo "$existing_json" | jq --arg shape "$SHAPE" \
  '[.data[]? | select(.shape == $shape and ."lifecycle-state" != "TERMINATED") | ."shape-config"."memory-in-gbs"] | add // 0')
over_quota=$(jq -n --argjson uo "$used_ocpus" --argjson um "$used_mem" --argjson o "$OCPUS" --argjson m "$MEMORY_GB" \
  '($uo + $o > 4) or ($um + $m > 24)')
if [ "$over_quota" = "true" ]; then
  log "ขอเพิ่มแล้วจะเกินโควตาฟรี (ใช้อยู่ ${used_ocpus} OCPU / ${used_mem} GB) — หยุด"
  exit 1
fi

# ---------- หาค่าที่ต้องใช้อัตโนมัติ ----------
# subnet อาจอยู่ใน compartment ไหนก็ได้ (ไม่จำเป็นต้องเป็น root) ใช้ Search ค้นทั้งบัญชี
# ถ้า Search ไม่เจอค่อยถอยไปดูใน root compartment ตรงๆ
search_json=$(oci search resource structured-search \
  --query-text "query subnet resources where displayName = '$SUBNET_NAME'" 2>&1) || search_json='{}'
SUBNET_ID=$(echo "$search_json" | jq -r '[.data.items[]? | select(."lifecycle-state" == "AVAILABLE")][0].identifier // empty' 2>/dev/null)
if [ -z "$SUBNET_ID" ]; then
  subnet_json=$(oci network subnet list --compartment-id "$COMPARTMENT_ID" --all 2>&1) || subnet_json='{}'
  SUBNET_ID=$(echo "$subnet_json" | jq -r --arg name "$SUBNET_NAME" '[.data[]? | select(."display-name" == $name)][0].id // empty' 2>/dev/null)
fi
if [ -z "$SUBNET_ID" ]; then
  log "ไม่พบ subnet ชื่อ \"$SUBNET_NAME\" — ตรวจชื่อใน Networking > Virtual cloud networks"
  log "subnet ที่พบในบัญชี:"
  oci search resource structured-search --query-text "query subnet resources" 2>&1 \
    | jq -r '.data.items[]? | "  - " + ."display-name"' 2>/dev/null
  show_error "$search_json"
  exit 1
fi

# Ubuntu 24.04 ตัวเต็ม (ไม่เอา Minimal) สำหรับ ARM ตัวล่าสุด
IMAGE_ID=$(oci compute image list --compartment-id "$COMPARTMENT_ID" \
    --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
    --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --all 2>/dev/null \
  | jq -r '[.data[]? | select(."display-name" | test("Minimal") | not)][0].id // empty')
if [ -z "$IMAGE_ID" ]; then
  log "ไม่พบ image Ubuntu 24.04 สำหรับ $SHAPE"
  exit 1
fi

log "เริ่มขอเครื่อง $SHAPE ${OCPUS} OCPU / ${MEMORY_GB} GB ใน ${#ADS[@]} AD (ลองทุก ${RETRY_SECONDS} วินาที กด Ctrl+C เพื่อหยุด)"
log "subnet: $(reveal "$SUBNET_ID")"
log "image : $(reveal "$IMAGE_ID")"

metadata=$(jq -cn --arg key "$SSH_PUBLIC_KEY" '{ssh_authorized_keys: $key}')
shape_config=$(jq -cn --argjson o "$OCPUS" --argjson m "$MEMORY_GB" '{ocpus: $o, memoryInGBs: $m}')
wait_seconds=$RETRY_SECONDS
attempt=0

# ---------- วนขอจนได้ ----------
while true; do
  for ad in "${ADS[@]}"; do
    attempt=$((attempt + 1))
    # --no-retry: ให้ CLI ตอบกลับทันทีเมื่อเครื่องเต็ม แทนที่จะลองซ้ำเองข้างใน
    # (ลองซ้ำเองทำให้ช้าครั้งละ ~2 นาทีและโดน 429) การเว้นระยะให้สคริปต์คุมเอง
    output=$(oci compute instance launch --no-retry \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$ad" \
      --display-name "$INSTANCE_NAME" \
      --shape "$SHAPE" \
      --shape-config "$shape_config" \
      --image-id "$IMAGE_ID" \
      --boot-volume-size-in-gbs "$BOOT_GB" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --metadata "$metadata" 2>&1)
    status=$?

    if [ $status -eq 0 ]; then
      instance_id=$(echo "$output" | jq -r '.data.id' 2>/dev/null)
      summary "สำเร็จ! ได้เครื่องแล้ว (ครั้งที่ $attempt) id: $(reveal "$instance_id")"
      log "กำลังรอ Public IP..."
      for _ in $(seq 1 30); do
        ip=$(oci compute instance list-vnics --instance-id "$instance_id" 2>/dev/null | jq -r '.data[0]."public-ip" // empty')
        if [ -n "$ip" ]; then
          summary "Public IP: $(reveal "$ip")"
          summary "เข้าเครื่องจาก Windows:  ssh -i C:\\nginx-1.31.7\\key_oeacle_cloud\\ssh-key-2026-10-13.key ubuntu@$(reveal "$ip")"
          exit 0
        fi
        sleep 10
      done
      summary "ยังไม่ได้ Public IP — ดูได้ที่ Compute > Instances > $INSTANCE_NAME"
      exit 0
    fi

    if echo "$output" | grep -qi "out of host capacity\|out of capacity"; then
      log "ครั้งที่ $attempt: $ad ยังเต็ม (Out of capacity)"
      wait_seconds=$RETRY_SECONDS
    elif echo "$output" | grep -qi "TooManyRequests\|\"status\": 429"; then
      wait_seconds=$((wait_seconds * 2))
      [ $wait_seconds -gt 600 ] && wait_seconds=600
      log "ครั้งที่ $attempt: Oracle ขอให้ช้าลง (429) — เว้นระยะเป็น ${wait_seconds} วินาที"
    elif echo "$output" | grep -qi "LimitExceeded\|QuotaExceeded"; then
      log "เกินโควตาของบัญชี — หยุด ตรวจเครื่องที่มีอยู่ใน Compute > Instances"
      show_error "$output"
      exit 1
    else
      # error ที่ไม่รู้จัก (เช่น สิทธิ์ไม่พอ, ค่าผิด) ลองต่อไปก็ไม่หาย — หยุดแล้วแสดงข้อความ
      log "ครั้งที่ $attempt: เจอ error ที่ไม่ใช่เรื่องเครื่องเต็ม — หยุด"
      show_error "$output"
      exit 1
    fi
  done
  round=$(( ${round:-0} + 1 ))
  if [ "$ROUNDS" -gt 0 ] && [ "$round" -ge "$ROUNDS" ]; then
    summary "ลองครบ $ROUNDS รอบแล้ว ยังไม่ได้เครื่อง — รอรอบถัดไป"
    exit 0
  fi
  sleep "$wait_seconds"
done
