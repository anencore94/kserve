# 정적 분석: v0.13 → v0.16 CRD/Config 차이 (롤백 안전성 근거)

이 문서는 이 저장소의 실제 설치 매니페스트(`install/v0.13.0-rc0/kserve.yaml`, `install/v0.16.0/kserve.yaml`)와 현재 소스 트리를 직접 파싱해 얻은 **증거**입니다. 원자료는 [`crd-inventory.txt`](./crd-inventory.txt).

> 주의: 이 저장소에는 `v0.13.0` 최종 태그 매니페스트가 없고 `v0.13.0-rc0`만 있습니다. CRD 스키마 관점에서 rc0과 최종의 차이는 무시할 수준이지만, 운영 정밀도가 필요하면 실제 운영에 설치된 `inferenceservices` CRD를 `kubectl get crd ... -o yaml`로 받아 대조하세요.

## 1. CRD 인벤토리 diff

| 항목 | 결과 |
|------|------|
| **제거된 CRD** | **없음** |
| **추가된 CRD (7개)** | `llminferenceservices`, `llminferenceserviceconfigs` (LLM 서빙) · `localmodelcaches`, `localmodelnodegroups`, `localmodelnodes` (노드 로컬 모델 캐시) · `inferencepools`, `inferencemodels` (`inference.networking.x-k8s.io`, Gateway API Inference Extension) |

## 2. **저장 버전(storage version) 무변경 — 롤백 안전성의 핵심 근거**

업그레이드 전/후 모든 기존 CRD의 **served/stored version이 동일**합니다:

| CRD | v0.13 storage | v0.16 storage |
|-----|---------------|---------------|
| `inferenceservices` | **v1beta1** | **v1beta1** |
| `servingruntimes` / `clusterservingruntimes` | v1alpha1 | v1alpha1 |
| `inferencegraphs` | v1alpha1 | v1alpha1 |
| `trainedmodels` | v1alpha1 | v1alpha1 |
| `clusterstoragecontainers` | v1alpha1 | v1alpha1 |

**함의:**
- 저장 버전 전환이 없음 → **conversion webhook이 개입하지 않음** → etcd에 저장된 오브젝트를 다시 쓰지 않음.
- 스키마 변경은 **필드 추가(additive)** 뿐 (InferenceService CRD가 15,699 → 21,890 라인으로 증가했으나, 대부분은 새 predictor 필드 + 최신 k8s PodSpec 임베드). **제거되거나 필수(required)로 바뀐 최상위 필드는 확인되지 않음.**
- 따라서 **CRD 스키마 롤백 위험이 낮음**: 이전 CRD를 다시 적용하면 이전 스키마가 복원되며, 기존 v1beta1 오브젝트는 그대로 유효합니다. (Karpenter류의 다중 버전 변환에서 발생하는 "webhook은 앞으로만 변환" 함정에 해당하지 않음.)

## 3. `inferenceservice-config` ConfigMap diff

| 항목 | 결과 |
|------|------|
| **제거된 키** | **없음** |
| **추가된 키 (5개)** | `autoscaler`, `security`, `localModel`, `opentelemetryCollector`, `inferenceService` |
| **`deploy` 블록** | 변경 없음 |
| **`ingress` 블록** | 변경됨 (아래) |

`ingress` 블록 기본값 변화:
```diff
+    "enableGatewayApi": false,
+    "kserveIngressGateway": "kserve/kserve-ingress-gateway",
     "ingressGateway" : "knative-serving/knative-ingress-gateway",
-    "ingressService" : "istio-ingressgateway.istio-system.svc.cluster.local",
     "localGateway" : "knative-serving/knative-local-gateway",
```
- **Gateway API opt-in** 추가(`enableGatewayApi: false` 기본 off).
- 하드코딩된 `ingressService` 기본값 제거.
- **운영 주의**: ConfigMap을 out-of-band(직접 kubectl/kustomize)로 커스터마이즈했다면, **helm/차트 업그레이드가 커스텀 키를 자동 병합하지 않습니다.** 업그레이드 전 `inferenceservice-config`를 백업하고 diff 후 재적용하세요.

## 4. deploymentMode 리네임 — 소스 코드에서 확인한 **최대 위험**

v0.16은 배포 모드 용어를 바꿉니다: `RawDeployment → Standard`, `Serverless → Knative`.
현재 소스 트리(HEAD, v0.16.0 이후 커밋)에서 직접 확인한 사실:

- `pkg/constants/constants.go`:
  ```go
  LegacyServerless    DeploymentModeType = "Serverless"    // deprecated: use Knative
  LegacyRawDeployment DeploymentModeType = "RawDeployment" // deprecated: use Standard
  // ParseDeploymentMode(): Legacy* → Standard/Knative 로 정규화
  ```
- 그러나 `pkg/apis/serving/v1beta1/inference_service_validation.go`의 `validateDeploymentMode()`는 annotation과 `status.DeploymentMode`를 **정규화 없이 문자열 그대로 비교**합니다:
  ```go
  if ok && annotationDeploymentMode != statusDeploymentMode {
      return fmt.Errorf("update rejected: deploymentMode cannot be changed from '%s' to '%s'", ...)
  }
  ```
- `pkg/controller/.../utils/utils.go`의 `GetDeploymentMode()`는 **status 값을 최우선으로, 정규화 없이 그대로 반환**합니다:
  ```go
  if len(statusDeploymentMode) != 0 { return DeploymentModeType(statusDeploymentMode) } // 예: "Serverless"
  ```
  이후 컨트롤러의 `deploymentMode == constants.Knative`("Knative") 분기는 legacy 문자열 "Serverless"와 매칭되지 않습니다.

**결론:** v0.13에서 생성된 기존 InferenceService는 `status.DeploymentMode`에 **legacy 문자열**(`Serverless`/`RawDeployment`)을 갖고 있어, v0.16 업그레이드 후

1. 새 webhook이 업데이트/삭제를 거부하거나(upstream [issue #4798](https://github.com/kserve/kserve/issues/4798)),
2. 컨트롤러가 legacy 문자열을 새 이름 분기와 매칭하지 못해 잘못된 경로로 재조정할 수 있습니다.

이 버그는 **v0.16.0(0.16 라인의 유일한 릴리스)에서 미해결**이며, 수정(PR #5025 계열)은 **v0.17.1+/v0.18** 라인에 반영되었습니다.

**대응(반드시 테스트):** 업그레이드 컷오버 시 기존 ISVC의 mode를 새 용어로 **정규화**하세요.
```bash
# 예: Serverless → Knative (RawDeployment → Standard)
kubectl get isvc -A -o json \
 | jq -r '.items[] | select(.status.deploymentMode=="Serverless") | "\(.metadata.namespace) \(.metadata.name)"' \
 | while read ns n; do
     kubectl annotate isvc "$n" -n "$ns" serving.kserve.io/deploymentMode=Knative --overwrite
   done
```
kind 리허설의 `05-verify.sh` 5.3 단계가 이 "freeze"를 실제로 재현/관찰합니다.

## 5. 재현 방법

```bash
# CRD 인벤토리 재생성
python3 - <<'PY'
import yaml
# install/v0.13.0-rc0/kserve.yaml, install/v0.16.0/kserve.yaml 파싱 (crd-inventory.txt 참조)
PY
```
`crd-inventory.txt`는 위 §1–2를 생성한 원자료입니다.
