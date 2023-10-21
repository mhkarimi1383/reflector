#!/usr/bin/env bash

function sendEvent() {
    case $6 in
        Reflect)
			kubectl apply -f - <<EOF
apiVersion: v1
eventTime: $(date -u +"%Y-%m-%dT%H:%M:%S.000000Z")
firstTimestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
lastTimestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
involvedObject:
    kind: Reflect
    apiVersion: k8s.karimi.dev/v1
    name: $1
    namespace: $2
kind: Event
message: $5
metadata:
    name: reflect-$(shuf -n 8 -e {A..Z} {a..z} {0..9} | tr -d '\n')
    namespace: $2
type: $3
reportingComponent: hook-runner
reportingInstance: reflect-operator
reason: $4
action: $4
EOF
        ;;
        Secret)
			kubectl apply -f - <<EOF
apiVersion: v1
eventTime: $(date -u +"%Y-%m-%dT%H:%M:%S.000000Z")
firstTimestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
lastTimestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
involvedObject:
    kind: Secret
    apiVersion: v1
    name: $1
    namespace: $2
kind: Event
message: $5
metadata:
    name: reflect-$(shuf -n 8 -e {A..Z} {a..z} {0..9} | tr -d '\n')
    namespace: $2
type: $3
reportingComponent: hook-runner
reportingInstance: reflect-operator
reason: $4
action: $4
EOF
        ;;
        *)
            echo "Unknown kind $6"
        ;;
    esac
}

function cleanupK8sResource() {
    echo "$1" | jq -r 'del(.metadata.labels."dev.karimi.k8s/reflect", .metadata.annotations."dev.karimi.k8s/reflect-namespaces", .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields)'
}

function getMissingJSONStrings() {
    readarray -t first < <(echo "$1" | jq -r -c '.[]')
    readarray -t second < <(echo "$2" | jq -r -c '.[]')
    diffrence=$(echo "${first[@]}" "${second[@]}" | tr ' ' '\n' | sort | uniq -u)
    for i in "${first[@]}"
    do
        if echo "${diffrence[@]}" | grep -F --word-regexp "$i" > /dev/null
        then
            echo "$i"
        fi
    done
}

function cleanupRemovedNamespaces() {
    old=$(printf '%s' "$1" | jq -Rsa -r '. / ","')
    new=$(printf '%s' "$2" | jq -Rsa -r '. / ","')
    kind="$3"
    name="$4"
    getMissingJSONStrings "$old" "$new" | while read -r line
    do
        kubectl delete -n "$line" "$kind/$name"
    done
}

function k8sCreateOrReplace() {
    manifest=$(echo "$1" | jq -r ". | .metadata.labels.\"dev.karimi.k8s/reflected\" = \"true\" | tostring")
    echo "$manifest" | kubectl replace -f- || echo "$manifest" | kubectl apply -f-
}

NS_LIST_SECRET_TEMPLATE="dev.karimi.reflect.NAME.namespace-list"

function generateSecretName() {
    echo ${NS_LIST_SECRET_TEMPLATE//"NAME"/"$1"}
}

function getOrCreateSecret() {
    manifest="$1"
    namespace=$(echo "$manifest" | jq -r '.metadata.namespace')
    name=$(echo "$manifest" | jq -r '.metadata.name')
    secretName=$(generateSecretName "$name")
    current=$(kubectl get -n "$namespace" secret/"$secretName" -o json || echo "{
        \"metadata\": {
            \"name\": \"$secretName\",
            \"namespace\": \"$namespace\"
        },
        \"type\": \"dev.karimi.k8s/reflection-namespace-status\",
        \"apiVersion\": \"v1\",
        \"kind\": \"secret\",
        \"data\": {
            \"current-namespaces\": \"$(echo '' | base64)\"
        }
    }")
    k8sCreateOrReplace "$current"
    echo "$current"
}

function setSecretNamespaceList() {
    manifest="$1"
    namespace=$(echo "$manifest" | jq -r '.metadata.namespace')
    name=$(echo "$manifest" | jq -r '.metadata.name')
    secretName=$(generateSecretName "$name")
    encoded=$(echo "$2" | base64)
    current="{
        \"metadata\": {
            \"name\": \"$secretName\",
            \"namespace\": \"$namespace\"
        },
        \"type\": \"dev.karimi.k8s/reflection-namespace-status\",
        \"apiVersion\": \"v1\",
        \"kind\": \"secret\",
        \"data\": {
            \"current-namespaces\": \"$encoded\"
        }
    }"
    k8sCreateOrReplace "$current"
    echo "$current"
}

function applyNamespaceListDiffrence() {
    manifest="$1"
    kind=$(echo "$manifest" | jq -r '.kind')
    name=$(echo "$manifest" | jq -r '.metadata.name')
    secretName=$(generateSecretName "$name")
    namespaces=""
    secret=$(getOrCreateSecret "$manifest")
    case "${kind}" in
        Secret)
            namespaces=$(echo "$manifest" | jq -r ".metadata.annotations.\"dev.karimi.k8s/reflect-namespaces\"")
        ;;
        Reflect)
            namespaces=$(echo "$manifest" | jq -r '.spec.namespace | join(",")')
        ;;
        *)
            echo "Unknown kind"
        ;;
    esac
    oldList=$(echo "$secret" | jq -r '.data."current-namespaces"' | base64 -d)

    cleanupRemovedNamespaces "$oldList" "$namespaces" "$kind" "$name"
    setSecretNamespaceList "$manifest" "$namespaces"
}

function validateNamespaceExistance() {
    if kubectl get namespace -o name | grep -E "^namespace/$1\$" - >> /dev/null; then
        echo "1"
    else
        echo "0"
    fi
}

function checkIfItsMe() {
    if [[ "$1" == "$OPERATOR_USERNAME" ]]; then
        echo "1"
    else
        echo "0"
    fi
}

ARRAY_COUNT=$(jq -r '. | length-1' "$BINDING_CONTEXT_PATH")

if [[ $1 == "--config" ]] ; then
	cat <<EOF
{
	"configVersion":"v1",
	"kubernetesValidating": [
		{
			"name": "reflect-validator.k8s.karimi.dev",
			"rules": [
				{
					"apiVersions": ["v1"],
					"apiGroups": ["k8s.karimi.dev"],
					"resources": ["reflects"],
					"operations": ["CREATE", "UPDATE"],
					"scope": "Namespaced"
				},
			],
			"failurePolicy": "Fail"
		},
		{
			"name": "reflected-secret-validator.k8s.karimi.dev",
			"labelSelector": {
				"matchLabels": {
					"dev.karimi.k8s/reflect": "true"
				}
			},
			"rules": [
				{
					"operations": ["CREATE", "UPDATE"],
					"apiVersions": ["v1"],
					"apiGroups": [""],
					"resources": ["secrets"],
					"scope": "Namespaced"
				}
			],
			"failurePolicy": "Fail"
		},
		{
			"name": "reflected-resources-protection.k8s.karimi.dev",
			"labelSelector": {
				"matchLabels": {
					"dev.karimi.k8s/reflected": "true"
				}
			},
			"rules": [
				{
					"operations": ["*"],
					"apiVersions": ["*"],
					"apiGroups": ["*"],
					"resources": ["*"],
					"scope": "Namespaced"
				}
			],
			"failurePolicy": "Fail"
		}
	],
	"kubernetes": [
		{
			"name": "ReflectObject",
			"apiVersion": "k8s.karimi.dev/v1",
			"kind": "Reflect",
			"executeHookOnEvent":["Added", "Modified", "Deleted"]
		},
		{
			"name": "SecretWatcher",
			"apiVersion": "v1",
			"kind": "Secret",
			"executeHookOnEvent": [ "Added", "Modified", "Deleted" ],
			"labelSelector": {
				"matchLabels": {
					"dev.karimi.k8s/reflect": "true"
				}
			}
		}
	]
}
EOF
else
    type=$(jq -r '.[0].type' "$BINDING_CONTEXT_PATH")
    case $type in
        Synchronization)
            echo "Got Synchronization event"
        ;;

        Validating)
            for IND in $(seq 0 "$ARRAY_COUNT")
            do
                kind=$(jq -r ".[$IND].review.request.object.kind" "$BINDING_CONTEXT_PATH")
                binding=$(jq -r ".[$IND].binding" "$BINDING_CONTEXT_PATH")
                case $binding in
                    "reflected-resources-protection.k8s.karimi.dev")
                        username=$(jq -r ".[$IND].review.request.userInfo.username" "$BINDING_CONTEXT_PATH")
                        if [[ $(checkIfItsMe "$username") == "1" ]]
                        then
							cat <<EOF > "$VALIDATING_RESPONSE_PATH"
{"allowed": true}
EOF
                        else
							cat <<EOF > "$VALIDATING_RESPONSE_PATH"
{"allowed": false, "message": "You are not able to delete/update reflected objects"}
EOF
                        fi
                    ;;

                    *)
                        case $kind in
                            Reflect)
                                namespaceCount=$(jq -r ".[$IND].review.request.object.spec.namespaces | length-1" "$BINDING_CONTEXT_PATH")
                                notFound=""
                                isValid="1"
                                for CURNS in $(seq 0 "$namespaceCount")
                                do
                                    namespace=$(jq -r ".[$IND].review.request.object.spec.namespaces[$CURNS]" "$BINDING_CONTEXT_PATH")
                                    if [[ $(validateNamespaceExistance "$namespace") == "1" ]] >> /dev/null; then
                                        echo "Found namespace $namespace"
                                    else
                                        echo "Missing namespace $namespace"
                                        notFound="$namespace $notFound"
                                        isValid="0"
                                    fi
                                done
                                if [[ $isValid == "1" ]]; then
									cat <<EOF > "$VALIDATING_RESPONSE_PATH"
{"allowed": true}
EOF
                                else
                                    notFound="${notFound%?}"
									cat <<EOF > "$VALIDATING_RESPONSE_PATH"
{"allowed": false, "message": "Namespaces ($notFound) does not exist. all of the namespaces should exist before creating new Reflect"}
EOF
                                fi
                            ;;

                            Secret)
                                namespaceList=$(jq -r ".[$IND].review.request.object.metadata.annotations.\"dev.karimi.k8s/reflect-namespaces\"" "$BINDING_CONTEXT_PATH")
                                # shellcheck disable=SC2206 # We want to have that spiliting behavior
                                namespaceArray=(${namespaceList//,/ })
                                notFound=""
                                isValid="1"
                                for namespace in "${namespaceArray[@]}"
                                do
                                    if [[ $(validateNamespaceExistance "$namespace") == "1" ]] >> /dev/null; then
                                        echo "Found namespace $namespace"
                                    else
                                        echo "Missing namespace $namespace"
                                        notFound="$namespace $notFound"
                                        isValid="0"
                                    fi
                                done
                                if [[ $isValid == "1" ]]; then
									cat <<EOF > "$VALIDATING_RESPONSE_PATH"
{"allowed": true}
EOF
                                else
                                    notFound="${notFound%?}"
									cat <<EOF > "$VALIDATING_RESPONSE_PATH"
{"allowed": false, "message": "Namespaces ($notFound) does not exist. all of the namespaces should exist before creating new Reflected Secret"}
EOF
                                fi
                            ;;
                            *)
                                echo "Unknown kind $kind"
                            ;;
                        esac
                    ;;
                esac
            done
        ;;

        Event)
            for IND in $(seq 0 "$ARRAY_COUNT")
            do
                resourceEvent=$(jq -r ".[$IND].watchEvent" "$BINDING_CONTEXT_PATH")
                resourceName=$(jq -r ".[$IND].object.metadata.name" "$BINDING_CONTEXT_PATH")
                resourceNamespace=$(jq -r ".[$IND].object.metadata.namespace" "$BINDING_CONTEXT_PATH")
                resourceKind=$(jq -r ".[$IND].object.kind" "$BINDING_CONTEXT_PATH")
                case $resourceKind in
                    Reflect)
                        reflectDestinationCount=$(jq -r ".[$IND].object.spec.namespaces | length-1" "$BINDING_CONTEXT_PATH")
                        reflectItemCount=$(jq -r ".[$IND].object.spec.items | length-1" "$BINDING_CONTEXT_PATH")
                        case $resourceEvent in
                            Added)
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Creating" "Working on creation..." "$resourceKind"
                                for CURNS in $(seq 0 "$reflectDestinationCount")
                                do
                                    namespace=$(jq -r ".[$IND].object.spec.namespaces[$CURNS]" "$BINDING_CONTEXT_PATH")
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on creation of resources in namespace $namespace..." "$resourceKind"
                                    for CURI in $(seq 0 "$reflectItemCount")
                                    do
                                        resource=$(jq -r ".[$IND].object.spec.items[$CURI] | .metadata.namespace = \"$namespace\" | tostring" "$BINDING_CONTEXT_PATH")
                                        k8sCreateOrReplace "$resource"
                                    done
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." "$resourceKind"
                                done
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Created" "created resources." "$resourceKind"
                            ;;

                            Modified)
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Updating" "Working on updates..." "$resourceKind"
                                for CURNS in $(seq 0 "$reflectDestinationCount")
                                do
                                    namespace=$(jq -r ".[$IND].object.spec.namespaces[$CURNS]" "$BINDING_CONTEXT_PATH")
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on update of resources in namespace $namespace..." "$resourceKind"
                                    currentManifest=$(jq -r ".[$IND].object.spec.items[$CURI] | tostring" "$BINDING_CONTEXT_PATH")
                                    applyNamespaceListDiffrence "$currentManifest"
                                    for CURI in $(seq 0 "$reflectItemCount")
                                    do
                                        resource=$(jq -r ".[$IND].object.spec.items[$CURI] | .metadata.namespace = \"$namespace\" | tostring" "$BINDING_CONTEXT_PATH")
                                        k8sCreateOrReplace "$resource"
                                    done
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." "$resourceKind"
                                done
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Updated" "created/updated resources." "$resourceKind"
                            ;;

                            Deleted)
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Removing" "Working on removal..." "$resourceKind"
                                for CURNS in $(seq 0 "$reflectDestinationCount")
                                do
                                    namespace=$(jq -r ".[$IND].object.spec.namespaces[$CURNS]" "$BINDING_CONTEXT_PATH")
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on removal of resources in namespace $namespace..." "$resourceKind"
                                    for CURI in $(seq 0 "$reflectItemCount")
                                    do
                                        resource=$(jq -r ".[$IND].object.spec.items[$CURI] | .metadata.namespace = \"$namespace\" | tostring" "$BINDING_CONTEXT_PATH")
                                        echo "$resource" | kubectl delete -f-
                                    done
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." "$resourceKind"
                                done
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Removed" "removed resources." "$resourceKind"
                            ;;

                            *)
                                echo "Unknown operation $resourceEvent on $resourceName in namespace $resourceNamespace"
                            ;;
                        esac
                    ;;
                    Secret)
                        namespaceList=$(jq -r ".[$IND].object.metadata.annotations.\"dev.karimi.k8s/reflect-namespaces\"" "$BINDING_CONTEXT_PATH")
                        # shellcheck disable=SC2206 # We want to have that spiliting behavior
                        namespaceArray=(${namespaceList//,/ })
                        case $resourceEvent in
                            Added)
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Creating" "Working on creation..." "$resourceKind"
                                for namespace in "${namespaceArray[@]}"
                                do
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on creation of Secret in namespace $namespace..." "$resourceKind"
                                    resource=$(jq -r ".[$IND].object | .metadata.namespace = \"$namespace\" | tostring" "$BINDING_CONTEXT_PATH")
                                    resource=$(cleanupK8sResource "$resource" | jq -r 'tostring')
                                    k8sCreateOrReplace "$resource"
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." "$resourceKind"
                                done
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Created" "created secrets." "$resourceKind"
                            ;;
                            Modified)
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Updating" "Working on updates..." "$resourceKind"
                                currentManifest=$(jq -r ".[$IND].object.spec.items[$CURI] | tostring" "$BINDING_CONTEXT_PATH")
                                applyNamespaceListDiffrence "$currentManifest"
                                for namespace in "${namespaceArray[@]}"
                                do
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on create/update of Secret in namespace $namespace..." "$resourceKind"
                                    resource=$(jq -r ".[$IND].object | .metadata.namespace = \"$namespace\" | tostring" "$BINDING_CONTEXT_PATH")
                                    resource=$(cleanupK8sResource "$resource" | jq -r 'tostring')
                                    k8sCreateOrReplace "$resource"
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." "$resourceKind"
                                done
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Updated" "created/updated secrets." "$resourceKind"
                            ;;
                            Deleted)
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Removing" "Working on removal..." "$resourceKind"
                                for namespace in "${namespaceArray[@]}"
                                do
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on removal of Secret in namespace $namespace..." "$resourceKind"
                                    resource=$(jq -r ".[$IND].object | .metadata.namespace = \"$namespace\" | tostring" "$BINDING_CONTEXT_PATH")
                                    resource=$(cleanupK8sResource "$resource" | jq -r 'tostring')
                                    echo "$resource" | kubectl delete -f-
                                    sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." "$resourceKind"
                                done
                                sendEvent "$resourceName" "$resourceNamespace" Normal "Removed" "removed secrets." "$resourceKind"
                            ;;
                            *)
                                echo "Unknown Operation $resourceEvent"
                            ;;
                        esac
                    ;;
                    *)
                        echo "Unknown kind $kind"
                esac
            done
        ;;

        *)
            echo "Unknown type $type"
        ;;
    esac
fi

