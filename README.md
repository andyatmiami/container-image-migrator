# container-image-migrator
Copy container images from a source image registry to a target image registry

## Overview

The script (`container-image-migrator.sh`) is intended to provide an "easy" and repeatable means to migrate images from a source container registry to a target container registry.  It was originally created for the Kubeflow Notebooks community to switch from storing images on DockerHub to GHCR in response to DockerHub implementing fairly restrictive rate limits on April 1, 2025.


## Pre-Requistites

**Applications:**

- `bash`
- `skopeo`
- `jq`


## Usage

:warning: Script has only been tested against `bash` and `zsh` shells.  While it _may work_ in other shells - there are no promises/guarantees!
- ℹ️ Shell choice matters when determining:
   - the absolute path to the location of the script itself
       - used to create additional files for state management
    - whether or not the script was sourced
        - `main` function is **not invoked** if the script is sourced

`./container-image-migrator.sh -c <config file> [-t] [-x] [-h]`

**Arguments**
- `-c <config file>`
    - **required**
    - Path to JSON configuration file for the given migration run
- `-t`
    - **optional**
    - Enables a "testing" mode that will skip invoking `skopeo copy` command
        - Additionally, no `status` updates will be written to the `*.state` file
    - :warning: Other `skopeo` (read) commands will still execute and could count against any rate limiting for your account
- `-x`
    - **optional**
    - Enable shell tracing output - which can be beneficial to diagnose issues with the script
       - :warning: Can result in a lot of output being logged
       - :warning: Can leak credentials in output
- `-h`
    - **optional**
    - Prints a simple one-line usage statement and exits

**Environment Variables**
- `SOURCE_CONTAINER_REGISTRY_PASSWORD`
    - **optional**
    - Enables a _non-interactive login_ to the source container registry via the `skopeo login` command
    - If not provided - the script will prompt user for password
- `TARGET_CONTAINER_REGISTRY_PASSWORD`
    - **optional**
    - Enables a _non-interactive login_ to the target container registry via the `skopeo login` command
    - If not provided - the script will prompt user for password

### Example Configuration File

```
{
    "container_registries": {
        "source": {
            "host": "docker.io",
            "username": "andyatmiami"
        },
        "target": {
            "host": "quay.io",
            "username": "rh-ee-astonebe"
        }
    },
    "migration_plan": {
        "kubeflownotebookswg/kfam": {
            "target_repo": "rh-ee-astonebe/test-migration-target",
            "tag_jq_filters": [".*"]
        }
    }
}
```

#### `container_registries`

The `container_registries` object requires both a `source` and `target` object - and each of those adhere to the same schema:
- `host`
    - **required**
    - hostname of the container registry
- `username`
    - **optional**
    - username of the account to use on the container registry
        - absence of the `username` value will result in the script attempting unauthenticated/anonymous access
        - the script will check if you already have a valid login session for the given hostname for the container runtime detected on your system
            - in the event you are not logged into the given container registry **or** if your login does not match the provided `username` attribute, the script will prompt for the related password

Any other attributes that may be defined are simply ignored.

#### `migration_plan`

The `migration_plan` object expects dynamic keys that identify images within the source container registry subject to migration.  The key names follow the template: `<organization>/<image>`.  Each dynamic key adhere to the same schema:
- `target_repo`
    - **optional**
    - specifies the name of the image as it should appear in the target container registry to facilitate renaming the image as part of migration
    - should follow the template: `<organization>/<image>`
    - if not specified, the value of the parent key will be used
- `tag_jq_filters`
    - **optional**
    - JSON array of regular expressions to test via `jq` to identify tags subject to migration
    - a tag will be considered a viable migration candidate if it matches at least one of the provided regular expressions
    - if not specified, an implicit JSON array of `[".*"]` is used
        - this default behavior matches all tags

Any other attributes that may be defined are simply ignored.

### Invocation

```
./container-image-migrator.sh -c test.json |& tee output.log
```
- 💡 `|& tee output.log` is not required for the script to run - but is a good best practice to capture output from script for later analysis
    - `|&` will pipe both `stderr` and `stdin`
    - `tee output.log` will preserve script output in  your terminal as well as redirect it to a file named `output.log`

### Authentication

The `skopeo login` command is used to authenticate against the source and target container registries.  Upon each invocation of the script, it will **always**
perform a `login` if a `username` is provided in the config file for a given container registry.  The authentication file `skopeo` uses is a transient file that is created during script execution in the root of the project repo.  The file name is the name of the provided `-c` argument appended with a `.auth` suffix.  Upon script exit - this file is deleted.

The script supports 2 environment variables:
- `SOURCE_CONTAINER_REGISTRY_PASSWORD`
- `TARGET_CONTAINER_REGISTRY_PASSWORD`

If authenticated access is required for a given container registry - the password will attempted to be retrieved from the respective environment variable.  If the environment variable is unset - the script will prompt the user for the password.

## Technical Details

📋 TODO


