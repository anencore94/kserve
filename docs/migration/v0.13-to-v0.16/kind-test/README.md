# KServe v0.13 → v0.16 업그레이드 리허설 (local kind)

운영 클러스터에 손대기 전에, **v0.13에서 InferenceService를 만든 뒤 온라인으로 v0.16으로 업그레이드**하고, 예측이 계속 되는지 · 기존 오브젝트가 얼어붙지 않는지(#4798) · 롤백이 되는지를 로컬 kind 클러스터에서 그대로 재현하는 스크립트입니다.

## 사전 요구사항

| 도구 | 최소 버전 | 비고 |
|------|-----------|------|
| docker | 최신 | kind 노드 컨테이너 |
| kind | v0.30.0 | `kserve-deps.env`와 동일 |
| kubectl | 1.28+ | |
| helm | v3.16+ | OCI 차트 pull |
| curl | - | 예측 호출 |

> **네트워크**: 이 리허설은 `ghcr.io`(KServe 차트/이미지), `quay.io`(cert-manager), `docker.io`, `registry.k8s.io`(kind 노드), GCS 공개 버킷(sklearn 모델)에서 이미지를 받습니다. **레지스트리 egress가 막힌 샌드박스에서는 image pull 단계에서 실패합니다** — 레지스트리 접근이 가능한 로컬 환경에서 실행하세요.

## 실행

```bash
cd docs/migration/v0.13-to-v0.16/kind-test

# 한 번에 (RawDeployment 모드 = kind에 가벼움, 기본값)
./run-all.sh

# 또는 단계별로
./00-prereqs.sh
./01-create-cluster.sh        # kind + cert-manager + Gateway API CRD
./02-install-kserve-old.sh    # KSERVE_OLD(=v0.13.0) 설치
./03-deploy-sample.sh         # sklearn-iris ISVC 생성, "before" 상태 캡처
./04-upgrade.sh               # CRD → 컨트롤러 순서로 helm upgrade
./05-verify.sh                # 합격 판정 (아래 참조)
./06-rollback-drill.sh        # 컨트롤러 롤백 검증
./99-teardown.sh              # kind 클러스터 삭제
```

### 파라미터 (환경변수)

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `KSERVE_OLD` | `v0.13.0` | 현재 운영 버전 |
| `KSERVE_NEW` | `v0.16.0` | 타깃 버전. `v0.18.0` 등으로 바꿔 최신 라인 검증 가능 |
| `DEPLOYMENT_MODE` | `RawDeployment` | `Serverless`로 바꾸려면 Knative/Istio를 별도 설치해야 함 |
| `CLUSTER_NAME` | `kserve-upgrade` | kind 클러스터 이름 |

`KSERVE_NEW=v0.18.0 ./run-all.sh` 로 **권장 타깃(최신 라인)** 도 동일 시나리오로 검증하세요.

## 합격 기준 (05-verify.sh)

1. **5.1** 업그레이드 후에도 기존 ISVC가 `Ready`.
2. **5.2** `status.deploymentMode` 가 legacy 문자열(`RawDeployment`/`Serverless`)로 남는지 확인 — v0.16.0에서는 남는 것이 정상이며, 이는 5.3의 정규화 필요성을 보여줌.
3. **5.3 (핵심)** 기존 오브젝트를 **patch 할 수 있는지**. 거부되면 이슈 #4798 의 "freeze"이며, 스크립트가 정규화(annotate) 방법을 출력함.
4. **5.4** port-forward로 실제 예측(`:predict`) 성공.
5. **5.5** 신규 CRD(`llminferenceservices`, `localmodelcaches`)가 설치됨.

## 산출물

`artifacts/` 에 저장됩니다:
- `all-crs-backup.yaml` — 업그레이드 전 모든 CR 백업 (롤백 복구용)
- `inferenceservice-config-backup.yaml` — ConfigMap 백업
- `crd-*-old.yaml` — 업그레이드 전 CRD 스키마
- `mode-before.txt`, `isvc-before.yaml`, `prediction.json`, `patch-err.txt`

## 주의

- 스크립트는 **CRD 차트를 절대 `helm uninstall` 하지 않습니다.** CRD를 지우면 GC로 모든 InferenceService가 삭제됩니다.
- v0.13 리소스 차트의 OCI 이름이 릴리스마다 달랐어서(`kserve` / `kserve-resources`), `env.sh`의 `resolve_kserve_chart`가 존재하는 쪽을 자동 선택합니다.
- Serverless(Knative) 모드로 검증하려면 `hack/quick_install.sh -s` 의 Knative/Istio 설치 부분을 먼저 적용한 뒤 `DEPLOYMENT_MODE=Serverless`로 실행하세요.
