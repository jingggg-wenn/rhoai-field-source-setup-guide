# Request More G and VT vCPU (AWS Quota Increase)

Created: 2026-11-25
Last modified: 2026-11-25

GPU nodes for the workshop are `g6.2xlarge` instances (8 vCPU each). AWS counts
them against the EC2 quota **Running On-Demand G and VT instances**, which is
measured in vCPU, not in instances. That quota can be as low as **64 vCPU**,
which allows at most 8 `g6.2xlarge` nodes, and fewer if other G instances
already run in the account. To run more GPU nodes, ask AWS to raise the quota
before you scale the GPU MachineSet.

You need access to the AWS account behind the cluster. RHDP gives you that
access when the environment is ordered with **Enable OPEN Environment?**
checked (see [Before you start](README.md#before-you-start-order-the-environment)).

## When you need this

- You plan more GPU nodes than the quota allows:
  `GPU nodes x 8 vCPU > current G and VT quota`.
- A GPU machine stays in `Provisioning` or `Failed`, and
  `oc describe machine <name> -n openshift-machine-api` shows an error such as
  `VcpuLimitExceeded` or `You have requested more vCPU capacity than your current vCPU limit`.

Request the increase **at least half a day before the workshop**. The support
ticket is usually resolved within 30 minutes, but the new limit can take
another 1–2 hours to be provisioned (see [step 5](#step-5-follow-the-support-case)).

## How much to request

The quota is the **total** vCPU for all running G and VT instances in the region,
so request the new total, not the extra amount.

| GPU nodes (`g6.2xlarge`) | vCPU needed | Request at least |
| ------------------------ | ----------- | ---------------- |
| 8                        | 64          | 64 (default may already cover it) |
| 10                       | 80          | 96               |
| 15                       | 120         | 128              |
| 20                       | 160         | 176              |

Add a node or two of headroom, in case a machine fails and is replaced.

## Step 1: Find the cluster's AWS region

The quota is per region. Find the region the cluster runs in:

```bash
oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}{"\n"}'
```

## Step 2: Get the AWS console credentials

1. Open [demo.redhat.com](https://demo.redhat.com) and go to your provisioned
   environment.
2. Open the **Details** tab.
3. In the **Web Console Access** section (AWS), note the console URL, username,
   and password.

## Step 3: Sign in to the AWS console

1. Open the console URL from step 2 (or the
   [AWS Management Console](https://console.aws.amazon.com/)) and sign in with
   those credentials.
2. In the top-right region menu, switch to the region from step 1 (for example,
   `us-east-2`). A quota request in the wrong region has no effect on the cluster.

## Step 4: Request the quota increase

1. In the console search bar, search for **Service Quotas** and open it.
2. Select **AWS services**, then search for and open
   **Amazon Elastic Compute Cloud (Amazon EC2)**.
3. In the quota search box, search for **Running On-Demand G and VT instances**
   and open it. The page shows the **Applied account-level quota value**, which
   is the current limit.
4. Click **Request increase at account level**.
5. In **Increase quota value**, enter the new **total** vCPU limit (see
   [How much to request](#how-much-to-request)).
6. Click **Request**.

Other quotas, if you use different instance types:

| Instance types | Quota name | Quota code |
| -------------- | ---------- | ---------- |
| `g4dn`, `g5`, `g6`, `g6e` (GPU workers) | Running On-Demand G and VT instances | `L-DB2E81BA` |
| `p4d`, `p5` | Running On-Demand P instances | `L-417A185B` |
| `m5a`, `m6i`, `c6i` (CPU workers) | Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances | `L-1216C47A` |

## Step 5: Follow the support case

The request opens an AWS Support case.

1. In **Service Quotas**, open **Quota request history**. The request shows its
   status (`Pending`, `Case opened`, `Approved`, `Denied`) and a link to the
   support case.
2. Open the case in the **AWS Support Center**. If it is still waiting after
   30 minutes, add a reply that explains the use case, for example:
   *"Red Hat demo environment for a hands-on OpenShift AI workshop on
   `<date>`. We need `<n>` g6.2xlarge instances (`<n x 8>` vCPU) in `<region>`
   for GPU model serving."*
3. If the case lets you change its severity, set it to **General guidance**, or
   higher if the workshop is close.

How long it takes:

| Stage | Typical time |
| ----- | ------------ |
| Ticket resolved (request shows **Approved**) | Within 30 minutes |
| New limit provisioned and enforced by EC2 | Another 1–2 hours |

Until the new limit is provisioned, GPU machines above the old limit still fail
with a vCPU limit error. Wait until the **Applied account-level quota value** on
the quota page shows the new number before you scale the GPU MachineSet.

## Alternative: request from the AWS CLI

You can also check and request the quota from a terminal. Use **AWS CloudShell**
(the `>_` icon in the AWS console top bar, already signed in), or the `aws` CLI
on your machine configured with the access keys from the RHDP **Details** tab
(`aws configure`).

```bash
export AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
# In CloudShell, set it directly instead, for example: export AWS_REGION=us-east-2

# Current limit
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-DB2E81BA \
  --query 'Quota.Value'

# Request a new total limit (for example, 128 vCPU)
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-DB2E81BA --desired-value 128
```

Then continue with [step 3](README.md#step-3-gpu_machineset_hardwareprofilessh)
of the workshop prep guide.
