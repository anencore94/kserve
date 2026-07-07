# KServe v0.13 → v0.16 온라인 업그레이드 런북

운영 중인 클러스터에서 KServe를 **v0.13에서 최신 라인까지 무중단(online) 업그레이드**하기 위한 실전 런북입니다.
근거는 (1) 공식 릴리스 노트/문서 리서치, (2) 이 저장소의 실제 설치 매니페스트(`install/v0.13.0-rc0` vs `install/v0.16.0`) 정적 분석, (3) 현재 소스 트리 코드 확인입니다. 정적 분석 원자료는 [`analysis/`](./analysis/), 로컬 검증 시나리오는 [`kind-test/`](./kind-test/).

---

## ⚠️ 먼저 읽을 것 — 타깃 버전 결정

이 작업은 "v0.13 → v0.16"으로 시작했지만, 리서치 결과 **두 가지를 먼저 짚어야 합니다.**

1. **v0.16은 최신이 아닙니다.** 오늘 기준 KServe는 **v0.17.x → v0.18.x → v0.19.0(2026-06-14)** 까지 나와 있습니다. v0.16.0은 2025-11-03 릴리스로 0.16 라인의 **유일한** 릴리스(v0.16.1 없음)입니다. 이 fork의 차트는 `v0.16.0`에 고정돼 있습니다.
2. **v0.16.0에는 온라인 마이그레이션을 깨뜨리는 미해결 버그가 있습니다** — deploymentMode 리네임(`Serverless→Knative`, `RawDeployment→Standard`)으로 인해 **기존 InferenceService가 얼어붙는** [issue #4798](https://github.com/kserve/kserve/issues/4798). 수정은 0.16 라인이 아니라 **v0.17.1+/v0.18** 에 반영되었습니다.

### 권장 타깃

| 선택 | 언제 | 트레이드오프 |
|------|------|--------------|
| **v0.18.x / v0.19.0 (권장)** | 운영 무중단 마이그레이션 | #4798 등 수정 포함. 이 fork에 없는 상위 차트/이미지 사용. K8s 1.32+ 요구 가능성 → 사전 확인 |
| 단계적 v0.13 → v0.15.2 → v0.18 | 가장 보수적 | ModelMesh/Helm 변경(0.15)과 deploymentMode 리네임+수정(0.17+)을 한 번에 안 맞고 분리 흡수 |
| v0.16.0 (fork 고정) | 굳이 0.16에 맞춰야 할 때 | 기존 ISVC deploymentMode **정규화 패스 필수** (아래 §5-A). 프로덕션 비권장 |

> 아래 절차는 `KSERVE_NEW` 변수만 바꾸면 어느 타깃에도 그대로 적용됩니다. 런북/스크립트는 v0.16을 기본값으로 두되, **프로덕션은 v0.18.x 이상을 권장**합니다.

### 아직 확인이 필요한 입력값 (작업 전 결정)

- **현재 배포 모드**: Serverless(Knative) / RawDeployment — #4798 노출도를 좌우.
- **현재 설치 방식**: Helm / kubectl(raw) / Kustomize — 업그레이드 명령을 좌우.
- **커스텀 Python 런타임 이미지 사용 여부** — pydantic v2 / Python 3.12 / uv 리빌드 필요(§5-F).

---

## 1. 업그레이드하면 무엇이 좋은가 (Why)

- **보안 패치**: v0.15.2에서 `CVE-2025-43859`, storage-initializer의 HuggingFace 토큰 노출 취약점(0.16) 등 다수 수정. 3개 마이너 버전만큼의 CVE 부채 해소.
- **GenAI/LLM 서빙 1급 지원**: HuggingFace 런타임 고도화, vLLM `0.6.1` → `0.9.2`, OpenAI 호환 엔드포인트(임베딩 포함), speculative decoding, tool/function calling, reasoning parser.
- **오토스케일링 확장**: **KEDA** 통합(0.15) — Knative KPA/HPA를 넘어 LLM 커스텀 메트릭으로 스케일. OpenTelemetry 기반 다중 메트릭(0.16).
- **네트워킹 현대화**: **Gateway API** 지원(0.15+, Raw/Standard) — Istio 종속을 줄이는 경로.
- **운영 편의**: 모델/트랜스포머/익스플레이너 **Stop/Resume**, raw deployment progressive rollout, 다중 storage URI, S3용 CA 번들 주입, blob(S3/GCS/Azure) 추론 로깅.
- **성능/GPU**: NVIDIA **MIG** 인식, **멀티노드/멀티GPU**(LeaderWorkerSet), OCI/ModelCar 기반 모델 배포, 노드 로컬 **모델 캐시**로 콜드스타트 단축.

## 2. 추가로 쓸 수 있게 되는 기능 (신규 CRD/기능)

정적 분석에서 확인한 **신규 CRD 7종**([근거](./analysis/crd-inventory.txt)):

| 신규 CRD | 기능 |
|----------|------|
| `llminferenceservices`, `llminferenceserviceconfigs` (0.16, v1alpha1) | **LLMInferenceService** — LLM 전용 API. prefix routing, disaggregated serving("llm-d"), HTTPRoute 재조정 |
| `localmodelcaches`, `localmodelnodegroups`, `localmodelnodes` (0.15/0.16) | **노드 로컬 모델 캐시** — node-agent가 PVC로 모델 사전 다운로드/검증, 콜드스타트 단축 |
| `inferencepools`, `inferencemodels` (`inference.networking.x-k8s.io`, v1alpha2) | **Gateway API Inference Extension** 연동 |

이 외에 기존 `InferenceService`(v1beta1 유지)에 필드가 추가되어 다중 storage URI, MIG, 멀티노드, stop/resume, progressive rollout 등을 **API 스펙 변경 없이** 사용할 수 있습니다.

## 3. 업그레이드 경로 & 온라인 마이그레이션 절차

### 3.1 마이너 버전 건너뛰기?

KServe는 공식적으로 "순차 업그레이드 필수"라고 명시하지 않지만, "건너뛰기 안전"도 보장하지 않습니다. 설치 모델은 **선언적 replace(타깃 버전 매니페스트/차트 적용)**, **CRD 먼저 → 컨트롤러**입니다.
- CRD는 이 구간에서 **additive**라 v0.13→타깃 직접 적용이 스키마상 대체로 동작.
- 그러나 deploymentMode 리네임(0.16) + ModelMesh/Helm 변경(0.15) + pydantic/uv(0.16) 등 **행위 변경이 누적**되므로, 라이브 ISVC가 있는 운영 클러스터는 **단계적 경로(v0.13 → v0.15.2 → v0.18)** 를 권장합니다.

### 3.2 절차 (Helm, 권장)

> **불변 원칙: CRD 차트 먼저 → 리소스 차트. CRD 차트를 절대 `helm uninstall` 하지 말 것**(CR 전체가 GC로 삭제됨).

```bash
# 0) 백업 (롤백 안전망) — 반드시 먼저
kubectl get isvc,servingruntime,clusterservingruntime,inferencegraph,trainedmodel -A -o yaml > backup-crs.yaml
kubectl get configmap inferenceservice-config -n kserve -o yaml > backup-config.yaml
helm -n kserve get values kserve > backup-helm-values.yaml

# 1) CRD 먼저
helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
  --version ${KSERVE_NEW} -n kserve --wait

# 2) 컨트롤러 (배포 모드는 새 용어로: Standard 또는 Knative)
helm upgrade --install kserve oci://ghcr.io/kserve/charts/kserve-resources \
  --version ${KSERVE_NEW} -n kserve --wait \
  --set kserve.controller.deploymentMode=Standard   # 또는 Knative

# 3) (0.16 타깃일 때) 기존 ISVC deploymentMode 정규화 — §5-A
# 4) 컨트롤러 재시작 후 검증 — §6
```

### 3.3 절차 (kubectl / raw manifests)

```bash
# --server-side 필수: InferenceService CRD가 커서 client-side apply 한도를 초과
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/${KSERVE_NEW}/kserve.yaml
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/${KSERVE_NEW}/kserve-cluster-resources.yaml
```

### 3.4 무중단 특성

- 기존 InferenceService의 predictor Pod/Deployment는 컨트롤러 교체 중에도 계속 서빙합니다(컨트롤러는 데이터플레인이 아님).
- 컨트롤러가 새 버전으로 올라오면 기존 오브젝트를 재조정합니다 — 이때 §5-A(deploymentMode)와 §5-C(런타임 이미지) 이슈가 드러날 수 있으니 **카나리 네임스페이스에서 먼저** 관찰하세요.

## 4. 실패 시 롤백 가능한가? (Rollback) — **가능, 단 조건부**

정적 분석이 뒷받침하는 결론([근거](./analysis/README.md)):

- ✅ **CRD 스키마 롤백 위험 낮음**: 모든 기존 CRD의 **저장 버전이 무변경**(`inferenceservices`는 v1beta1 유지). **conversion webhook 없음**, etcd 재기록 없음. 이전 CRD를 다시 적용하면 이전 스키마 복원, 기존 오브젝트 유효.
- ✅ **컨트롤러 롤백은 빠르고 안전**: `helm rollback kserve` 또는 이전 버전으로 `helm upgrade`. CR은 삭제되지 않음.
- ⚠️ **단 하나의 일방향 항목**: 새 컨트롤러가 오브젝트의 `status.deploymentMode`를 **새 용어(Standard/Knative)로 이미 재기록**했다면, 이전 컨트롤러가 이를 인식 못 할 수 있음(#4798의 거울상). → 백업한 CR(`backup-crs.yaml`, legacy 상태 보존)을 재적용하거나 annotation을 legacy 값으로 되돌려 해결.
- 🚫 **절대 금지**: 롤백 과정에서 `helm uninstall kserve-crd` — 클러스터의 모든 InferenceService/ServingRuntime가 GC로 삭제됩니다.

롤백 절차는 [`kind-test/06-rollback-drill.sh`](./kind-test/06-rollback-drill.sh)로 재현/검증합니다.

## 5. 마이그레이션 유의사항 (Precautions)

### 5-A. (최대 위험) deploymentMode 리네임 — 기존 ISVC 프리즈 #4798
`Serverless→Knative`, `RawDeployment→Standard`. v0.13에서 만든 ISVC는 `status.deploymentMode`에 **legacy 문자열**을 보유 → v0.16.0 webhook이 업데이트/삭제를 거부하거나 컨트롤러가 오분기. **v0.16.0 미해결, v0.17.1+/v0.18에서 수정.** 코드 근거와 정규화 스크립트는 [`analysis/README.md` §4](./analysis/README.md).

```bash
# 0.16 타깃일 때 컷오버 시 1회 정규화
kubectl get isvc -A -o json \
 | jq -r '.items[]|select(.status.deploymentMode=="Serverless")|"\(.metadata.namespace) \(.metadata.name)"' \
 | while read ns n; do kubectl annotate isvc "$n" -n "$ns" serving.kserve.io/deploymentMode=Knative --overwrite; done
# RawDeployment 사용 시 값만 Standard 로
```

### 5-B. `inferenceservice-config` ConfigMap
- 키 제거는 없고 5개 추가(`autoscaler`,`security`,`localModel`,`opentelemetryCollector`,`inferenceService`), `ingress` 블록에 `enableGatewayApi`/`kserveIngressGateway` 추가, `ingressService` 기본값 제거([diff](./analysis/README.md#3)).
- **ConfigMap을 out-of-band로 커스터마이즈했다면 차트 업그레이드가 병합하지 않음** → 반드시 백업 후 diff/재적용.
- v0.15.2부터 **ModelCar/OCI가 기본 활성** — storage-initializer 설정과의 상호작용 확인.

### 5-C. ServingRuntime / 런타임 이미지
- v0.16에서 일부 내장 ServingRuntime이 기본 비활성화, vLLM `0.9.2`/Torch `2.7.0`로 점프. **ISVC가 참조하는 런타임 이미지 태그가 존재/호환하는지** 확인.
- 0.16: standard predictor에서 `name` 필드 불허, `-default` suffix 호환 제거 → 해당 스펙 감사.

### 5-D. Storage initializer
- 모델 다운로드 로직이 storage-initializer로 이동(0.14), S3 CA 번들 주입/다중 URI(0.16). 사설 S3/HF·커스텀 CA 사용 시 재검증.

### 5-E. ModelMesh
- **v0.15에서 ModelMesh Helm 설치 제거.** ModelMesh 사용 중이면 별도 마이그레이션 필요.

### 5-F. 커스텀 Python 런타임
- **pydantic v1 제거(0.16)**, Python 3.8 제거/3.12 추가(0.14), Ray optional(0.14), SDK storage 모듈 분리(0.16), Poetry→uv(0.16). 커스텀 predictor/transformer 이미지 **리빌드 & 테스트**.

### 5-G. 배포 모드별
- Serverless: #4798 노출 최대. RawDeployment: `RawDeployment→Standard` 리네임만 해당하나 정규화는 여전히 필요. Standard 모드는 HTTP scale-to-zero 미지원(기존 동작, 용량 계획 확인).

### 5-H. 사전 요구사항 확인
- 릴리스 노트에 **최소 K8s 버전이 명시되지 않음.** 현재 문서(0.18 대상)는 **K8s 1.32+, cert-manager ≥1.15, Gateway API 1.2.1, Istio 1.27+** 요구. **타깃 버전의 공식 문서 prerequisites를 클러스터 baseline과 대조**하세요(리서치 환경에서 `kserve.github.io` 접근 차단으로 0.16 정확 최소값 미확정).

## 6. 검증 (Verification)

업그레이드 후 다음을 확인(상세는 [`kind-test/05-verify.sh`](./kind-test/05-verify.sh)):

```bash
kubectl -n kserve rollout status deploy/kserve-controller-manager
kubectl get isvc -A                      # 모두 READY=True 유지?
kubectl get crd | grep kserve.io         # 신규 CRD 존재?
# 기존 오브젝트 mutate 가능한지(프리즈 여부)
kubectl label isvc <name> -n <ns> smoke-test=ok --overwrite
# 실제 예측
curl -sf -d @input.json http://<endpoint>/v1/models/<name>:predict
```

## 7. 로컬 kind 리허설 → 실제 태스크

운영에 적용하기 전에 [`kind-test/`](./kind-test/)로 **동일 시나리오를 로컬에서 리허설**하세요:

```bash
cd docs/migration/v0.13-to-v0.16/kind-test
./run-all.sh                       # v0.13 설치→ISVC→v0.16 업그레이드→검증→롤백
KSERVE_NEW=v0.18.0 ./run-all.sh    # 권장 타깃도 동일 검증
```
`05-verify.sh`가 #4798 프리즈를 실제로 재현/관찰하고, `06-rollback-drill.sh`가 롤백 안전성을 증명합니다.

> **참고**: 이 스크립트는 레지스트리(ghcr.io/quay.io/docker.io/registry.k8s.io)에서 이미지를 받으므로 egress가 열린 로컬에서 실행해야 합니다. 본 작업이 수행된 샌드박스는 모든 컨테이너 레지스트리 egress가 정책상 차단되어(문서화된 조직 정책) **라이브 kind 실행은 로컬에서 진행**해야 합니다. 대신 이 저장소에서 가능한 **정적 검증(CRD/Config diff, 코드 확인, 스크립트 문법 검증)** 은 모두 수행해 근거로 첨부했습니다.

---

## 부록: 근거 자료
- 정적 분석: [`analysis/README.md`](./analysis/README.md), [`analysis/crd-inventory.txt`](./analysis/crd-inventory.txt)
- 리허설 스크립트: [`kind-test/`](./kind-test/)
- 주요 출처: KServe 릴리스 노트(v0.14/0.15/0.15.2/0.16.0), issue #4798, PR #5025, KServe website 문서(admin-guide), CNCF v0.15 announcement.
