# do-awte

This sets up a local Argo Workflows playground using kind (Kubernetes-in-Docker), then shows you
how to open the UI and run the example workflows. Bring snacks.

## TL;DR
- Prereqs:

  kind, kubectl, helm (and optionally the argo CLI)

- Setup: 

  `./scripts/setup-local.sh`

- Open UI: 

  `kubectl -n argo port-forward svc/argo-workflows-server 2746:2746`

  and visit http://localhost:2746

- Login:
 
  use the token printed by the setup script (paste it as `Bearer <token>`)

- Run a workflow: 

  `kubectl -n argo create -f workflows/simple-sample.yaml`

---

## 1) Prerequisites
You’ll need these installed and on your PATH:

- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
- [helm](https://helm.sh/docs/intro/install/)

Optional (nice-to-have):
- [Argo Workflows CLI](https://argo-workflows.readthedocs.io/en/latest/quick-start/)

## 2) Spin up the local cluster and Argo
Run the setup script from the repo root:

```shell
./scripts/setup-local.sh
```

What this does for you (a lot, frankly):
- Creates (or reuses) a kind cluster named `awte`
- Installs Argo Workflows via Helm into the argo namespace
- Creates a friendly demo `ServiceAccount` with just enough RBAC to be useful
- Prints an access token you can use to log into the Argo UI

Pro tips:
- You can pass flags like `--cluster-name` NAME or `--values deploy/local-values.yaml` if 
  you’re feeling fancy.

## 3) Open the Argo UI
In a new terminal, port-forward the Argo Server service:

```shell
kubectl -n argo port-forward svc/argo-workflows-server 2746:2746
```

Now open your browser to:

http://localhost:2746

For login, select “Authorization header” (or similar), and paste the token the setup script 
printed, prefixed with the word Bearer and a space, like:

```
Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...(blah blah blah)
```

If you lost the token (we all do), re-run the setup script; it will print it again or recreate 
one for you.

## 4) Register/submit and run workflows
We’ve included two example workflows in the `workflows/` folder. Submitting them “registers” them 
in the cluster and kicks them off.

Using kubectl (works everywhere):

```shell
# Simple hello-world style workflow
kubectl -n argo create -f workflows/simple-sample.yaml

# A slightly fancier dynamic fan-out example
kubectl -n argo create -f workflows/dynamic-split-usecase.yaml

# Check workflow status
kubectl -n argo get wf

# See node/state details for the most recent workflow
kubectl -n argo get wf -o wide
```

You can also watch logs in the UI, or via kubectl:

```shell
kubectl -n argo get pods
kubectl -n argo logs <some-pod-name>
```

Using the argo CLI (optional, if installed):

```shell
argo submit -n argo workflows/simple-sample.yaml --watch
```

## 5) Common “it’s not working” tips
- kind not found? Install it first: https://kind.sigs.k8s.io/
- kubectl context weird? The script creates a cluster named `awte`; ensure your context is 
  `kind-awte`. 
- UI won’t open? Make sure the port-forward is still running and that the 
  `argo-workflows-server` pod is Ready.
- Auth issues? Double-check you pasted the token with the `Bearer ` prefix.

## 6) Cleanup
If you want to reclaim your RAM like a responsible adult:

```
kind delete cluster --name awte
```

That’s it! You now have a local Argo playground. Use it wisely. Or unwisely. Your call.
