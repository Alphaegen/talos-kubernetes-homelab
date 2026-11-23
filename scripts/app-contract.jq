# The app-of-apps contract: rules that join a child Application to its
# AppProject and to what its local sources render. Prints one line per
# violation, "<rule>: <what is wrong>", and nothing when the contract holds.
# validate.sh builds the input; scripts/testdata/app-contract/ has one case per
# rule. The rules infra.application enforces on its own (waves, projects,
# FailOnSharedResource, ownsPVCs without cascadeDelete) are not repeated here.
#
# Input:
#   applications     the child Applications (infra-helm, every toggle on)
#   projects         the AppProjects
#   sources          {"<path>": [objects]} for each local source, rendered
#   toggles          [{path, enabled}] for every <component>.enabled key, as
#                    the CI render sees it (values.yaml + ci/all-enabled-values.yaml)
#   rootRetry        gitops/root-application.yaml's syncPolicy.retry
#   probeNamespaces  require-probes' namespace list

def app_sources: [(.spec.source // empty), (.spec.sources // [] | .[])] | map(select(.ref == null));
def creates_namespace: (.spec.syncPolicy.syncOptions // []) | index("CreateNamespace=true") != null;
def owns_pvcs: [.spec.ignoreDifferences // [] | .[] | select(.kind == "PersistentVolumeClaim")] | length > 0;
def id: "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name)";
def group_of: if (.apiVersion | contains("/")) then .apiVersion | split("/")[0] else "" end;
# Namespaces that exist without an owner in Git.
def system_namespaces: ["default", "kube-system"];

. as $in
| ($in.projects | map({key: .metadata.name, value: .spec}) | from_entries) as $projects
| [$in.applications[] | {
    app: .,
    name: .metadata.name,
    project: .spec.project,
    namespace: .spec.destination.namespace,
    objects: [app_sources[] | select(.path != null) | $in.sources[.path] // [] | .[]]
  }] as $apps

# project: the AppProject lists every namespace an Application deploys to and
# every repository it reads; Argo CD would only refuse these at sync time.
| ($apps[] | . as $a | $projects[$a.project] as $p
    | if $p == null then
        "project: \($a.name) uses AppProject \($a.project), which does not exist"
      else
        ([$p.destinations[].namespace] as $allowed
          | [$a.namespace, ($a.objects[] | .metadata.namespace // empty),
             ($a.objects[] | select(.kind == "Namespace") | .metadata.name)] | unique[]
          | select(. as $ns | $allowed | index($ns) | not)
          | "project: \($a.name) deploys to namespace \(.), which AppProject \($a.project) does not list"),
        ($a.app | app_sources[] | .repoURL as $repo
          | select($p.sourceRepos | index($repo) | not)
          | "project: \($a.name) reads \($repo), which AppProject \($a.project) does not list in sourceRepos"),
        # Local sources name the namespace of every namespaced object, so an
        # object without one is cluster-scoped and needs the project's leave.
        ($a.objects[] | select(.metadata.namespace == null) | . as $o
          | select([$p.clusterResourceWhitelist // [] | .[]
              | select((.group == "*" or .group == ($o | group_of)) and (.kind == "*" or .kind == $o.kind))]
              | length == 0)
          | "project: \($a.name) renders \($o | id) without a namespace; AppProject \($a.project) does not allow it cluster-wide (namespaced objects must name their namespace)")
      end)

# owns-pvcs: an Application whose source holds PVCs sets ownsPVCs.
, ($apps[] | select(.app | owns_pvcs | not) | . as $a
    | [.objects[] | select(.kind == "PersistentVolumeClaim") | .metadata.name] | select(length > 0)
    | "owns-pvcs: \($a.name) renders PersistentVolumeClaim \(join(", ")) but does not set ownsPVCs")

# namespace: every destination has an owner: a Namespace manifest in a source
# or an Application that creates it. A source that owns its Namespace does not
# also let Argo CD create it. (Two manifests are a single-owner violation.)
, ([$apps[] | .name as $name | .objects[] | select(.kind == "Namespace")
      | {namespace: .metadata.name, owner: $name}] as $manifests
    | ($apps[] | select(.app | creates_namespace) | . as $a
        | select([$manifests[] | select(.namespace == $a.namespace)] | length > 0)
        | "namespace: \($a.name) sets createNamespace, but namespace \($a.namespace) has a Namespace manifest; leave createNamespace off"),
      ([$apps[].namespace] | unique[] | . as $ns
        | select(system_namespaces | index($ns) | not)
        | select([$manifests[] | select(.namespace == $ns)] + [$apps[] | select(.namespace == $ns and (.app | creates_namespace))]
            | length == 0)
        | "namespace: nothing creates namespace \($ns): add a Namespace manifest to a source or set createNamespace"))

# single-owner: no object is rendered by two Applications.
, ([$apps[] | .name as $name | .objects[] | {id: id, owner: $name}]
    | group_by(.id)[] | (map(.owner) | unique) as $owners | select($owners | length > 1)
    | "single-owner: \(.[0].id) is rendered by \($owners | join(" and "))")

# ci-toggles: the CI render switches every toggle on, so no template goes
# unrendered.
, ($in.toggles[] | select(.enabled != true)
    | "ci-toggles: \(.path).enabled is off in the CI render; switch it on in gitops/infra-helm/ci/all-enabled-values.yaml")

# root-retry: the root Application repeats infra.syncPolicy's retry by hand.
, ([$apps[].app.spec.syncPolicy.retry] | unique | select(. != [$in.rootRetry])
    | "root-retry: gitops/root-application.yaml's retry differs from infra.syncPolicy's; keep them the same")

# probes: require-probes covers every apps namespace (docs/adr/0004).
, ($projects.apps.destinations // [] | .[].namespace
    | select(. as $ns | $in.probeNamespaces | index($ns) | not)
    | "probes: apps namespace \(.) is missing from require-probes")
