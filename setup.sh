#!/usr/bin/env bash

setup() {
    # Runs the entire project setup, leading to a collection of environment variables starting with
    # "CF_", the installation of the software stack via virtual environments, and optionally an
    # interactive setup where the user can configure certain variables.
    #
    # Arguments:
    #   1. The name of the setup. "default" (which is itself the default when no name is set)
    #      triggers a setup with good defaults, avoiding all queries to the user and the writing of
    #      a custom setup file. See "interactive_setup" for more info.
    #
    # Optinally preconfigured environment variables:
    #   CF_REINSTALL_SOFTWARE : If "1", any existing software stack is removed and freshly
    #                           installed.
    #   CF_REMOTE_JOB         : If "1", applies configurations for remote job. Remote jobs will set
    #                           this value if needed and there is no need to set this by hand.
    #   CF_LCG_SETUP          : The location of a custom LCG software setup file.
    #   X509_USER_PROXY       : A custom globus user proxy location.
    #   LANGUAGE, LANG, LC_ALL: Custom language flags.

    #
    # prepare local variables
    #

    local this_file="$( [ ! -z "$ZSH_VERSION" ] && echo "${(%):-%x}" || echo "${BASH_SOURCE[0]}" )"
    local this_dir="$( cd "$( dirname "$this_file" )" && pwd )"
    local orig="$PWD"
    local setup_name="${1:-default}"
    local setup_is_default="false"
    [ "$setup_name" = "default" ] && setup_is_default="true"


    #
    # global variables
    # (CF = columnflow)
    #

    # lang defaults
    [ -z "$LANGUAGE" ] && export LANGUAGE="en_US.UTF-8"
    [ -z "$LANG" ] && export LANG="en_US.UTF-8"
    [ -z "$LC_ALL" ] && export LC_ALL="en_US.UTF-8"

    # proxy
    [ -z "$X509_USER_PROXY" ] && export X509_USER_PROXY="/tmp/x509up_u$( id -u )"

    export CF_BASE="$this_dir"
    interactive_setup "$setup_name" || return "$?"
    export CF_SETUP_NAME="$setup_name"
    export CF_STORE_REPO="$CF_BASE/data/store"
    export CF_VENV_PATH="${CF_SOFTWARE}/venvs"
    export CF_ORIG_PATH="$PATH"
    export CF_ORIG_PYTHONPATH="$PYTHONPATH"
    export CF_ORIG_PYTHON3PATH="$PYTHON3PATH"
    export CF_ORIG_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
    export CF_CI_JOB="$( [ "$GITHUB_ACTIONS" = "true" ] && echo 1 || echo 0 )"

    # overwrite some variables in remote and ci jobs
    if [ "$CF_REMOTE_JOB" = "1" ]; then
        export CF_WLCG_USE_CACHE="true"
        export CF_WLCG_CACHE_CLEANUP="true"
        export CF_WORKER_KEEP_ALIVE="false"
    elif [ "$CF_CI_JOB" = "1" ]; then
        export CF_WORKER_KEEP_ALIVE="false"
    fi

    # some variable defaults
    [ -z "$CF_WORKER_KEEP_ALIVE" ] && export CF_WORKER_KEEP_ALIVE="false"


    #
    # minimal local software setup
    #

    # use the latest centos7 ui from the grid setup on cvmfs
    [ -z "$CF_LCG_SETUP" ] && export CF_LCG_SETUP="/cvmfs/grid.cern.ch/centos7-ui-160522/etc/profile.d/setup-c7-ui-python3-example.sh"
    if [ -f "$CF_LCG_SETUP" ]; then
        source "$CF_LCG_SETUP" ""
    elif [ "$CF_CI_JOB" = "1" ]; then
        2>&1 echo "LCG setup file $CF_LCG_SETUP not existing in CI env, skipping"
    else
        2>&1 echo "LCG setup file $CF_LCG_SETUP not existing"
        return "1"
    fi

    # update paths and flags
    local pyv="$( python3 -c "import sys; print('{0.major}.{0.minor}'.format(sys.version_info))" )"
    export PATH="$CF_BASE/bin:$CF_BASE/cf/scripts:$CF_BASE/modules/law/bin:$CF_SOFTWARE/bin:$PATH"
    export PYTHONPATH="$CF_BASE/modules/law:$CF_BASE/modules/order:$PYTHONPATH"
    export PYTHONPATH="$CF_BASE:$PYTHONPATH"
    export PYTHONWARNINGS="ignore"
    export GLOBUS_THREAD_MODEL="none"
    ulimit -s unlimited

    # local python stack in two virtual envs:
    # - "cf_prod": contains the minimal stack to run tasks and is sent alongside jobs
    # - "cf_dev" : "prod" + additional python tools for local development (e.g. ipython)
    if [ "$CF_REMOTE_JOB" != "1" ]; then
        if [ "$CF_REINSTALL_SOFTWARE" = "1" ]; then
            echo "removing software stack at ${CF_VENV_PATH}"
            rm -rf "${CF_VENV_PATH}"/cf_{prod,dev}
        fi

        show_version_warning() {
            2>&1 echo ""
            2>&1 echo "WARNING: your venv '$1' is not up to date, please consider updating it in a new shell with"
            2>&1 echo "         > CF_REINSTALL_SOFTWARE=1 source setup.sh $( $setup_is_default || echo "$setup_name" )"
            2>&1 echo ""
        }

        # source the prod and dev sandboxes
        source "${CF_BASE}/sandboxes/cf_prod.sh" "" "1"
        local ret_prod="$?"
        source "${CF_BASE}/sandboxes/cf_dev.sh" "" "1"
        local ret_dev="$?"

        # show version warnings
        [ "$ret_prod" = "21" ] && show_version_warning "cf_prod"
        [ "$ret_dev" = "21" ] && show_version_warning "cf_dev"
    else
        # source the prod sandbox
        source "${CF_BASE}/sandboxes/cf_prod.sh" ""
    fi


    #
    # initialze submodules
    #

    if [ -d "$CF_BASE/.git" ]; then
        for m in law order; do
            local mpath="$CF_BASE/modules/$m"
            # initialize the submodule when the directory is empty
            if [ "$( ls -1q "$mpath" | wc -l )" = "0" ]; then
                git submodule update --init --recursive "$mpath"
            else
                # update when not on a working branch and there are no changes
                local detached_head="$( ( cd "$mpath"; git symbolic-ref -q HEAD &> /dev/null ) && echo true || echo false )"
                local changed_files="$( cd "$mpath"; git status --porcelain=v1 2> /dev/null | wc -l )"
                if ! $detached_head && [ "$changed_files" = "0" ]; then
                    git submodule update --init --recursive "$mpath"
                fi
            fi
        done
    fi


    #
    # law setup
    #

    export LAW_HOME="$CF_BASE/.law"
    export LAW_CONFIG_FILE="$CF_BASE/law.cfg"

    if which law &> /dev/null; then
        # source law's bash completion scipt
        source "$( law completion )" ""

        # silently index
        law index -q
    fi
}

interactive_setup() {
    # Starts the interactive part of the setup by querying for values of certain environment
    # variables with useful defaults. When a custom, named setup is triggered, the values of all
    # queried environment variables are stored in a file in $CF_BASE/.setups.
    #
    # Arguments:
    #   1. The name of the setup. "default" (which is itself the default when no name is set)
    #      triggers a setup with good defaults, avoiding all queries to the user and the writing of
    #      a custom setup file.
    #   2. The location of the setup file when a custom, named setup was triggered. Defaults to
    #      "$CF_BASE/.setups/$setup_name.sh"
    #
    # Required environment variables:
    #   CF_BASE: The base path of the CF project.

    local setup_name="${1:-default}"
    local env_file="${2:-$CF_BASE/.setups/$setup_name.sh}"
    local env_file_tmp="$env_file.tmp"

    # check if the setup is the default one
    local setup_is_default="false"
    [ "$setup_name" = "default" ] && setup_is_default="true"

    # when the setup already exists and it's not the default one,
    # source the corresponding env file and stop
    if ! $setup_is_default; then
        if [ -f "$env_file" ]; then
            echo -e "using variables for setup '\x1b[0;49;35m$setup_name\x1b[0m' from $env_file"
            source "$env_file" ""
            return "0"
        else
            echo -e "no setup file $env_file found for setup '\x1b[0;49;35m$setup_name\x1b[0m'"
        fi
    fi

    export_and_save() {
        local varname="$1"
        local value="$2"

        export $varname="$( eval "echo $value" )"
        ! $setup_is_default && echo "export $varname=\"$value\"" >> "$env_file_tmp"
    }

    query() {
        local varname="$1"
        local text="$2"
        local default="$3"
        local default_text="${4:-$default}"
        local default_raw="$default"

        # when the setup is the default one, use the default value when the env variable is empty,
        # otherwise, query interactively
        local value="$default"
        if $setup_is_default; then
            # set the variable when existing
            eval "value=\${$varname:-\$value}"
        else
            printf "$text (\x1b[1;49;39m$varname\x1b[0m, default \x1b[1;49;39m$default_text\x1b[0m):  "
            read query_response
            [ "X$query_response" = "X" ] && query_response="$default"

            # repeat for boolean flags that were not entered correctly
            while true; do
                ( [ "$default" != "True" ] && [ "$default" != "False" ] ) && break
                ( [ "$query_response" = "True" ] || [ "$query_response" = "False" ] ) && break
                printf "please enter either '\x1b[1;49;39mTrue\x1b[0m' or '\x1b[1;49;39mFalse\x1b[0m':  " query_response
                read query_response
                [ "X$query_response" = "X" ] && query_response="$default"
            done
            value="$query_response"

            # strip " and ' on both sides
            value=${value%\"}
            value=${value%\'}
            value=${value#\"}
            value=${value#\'}
        fi

        export_and_save "$varname" "$value"
    }

    # prepare the tmp env file
    if ! $setup_is_default; then
        rm -rf "$env_file_tmp"
        mkdir -p "$( dirname "$env_file_tmp" )"

        echo -e "Start querying variables for setup '\x1b[0;49;35m$setup_name\x1b[0m', press enter to accept default values\n"
    fi

    # start querying for variables
    query CF_CERN_USER "CERN username" "$( whoami )"
    export_and_save CF_CERN_USER_FIRSTCHAR "\${CF_CERN_USER:0:1}"
    query CF_DESY_USER "DESY username (if any)" "$( whoami )"
    export_and_save CF_DESY_USER_FIRSTCHAR "\${CF_DESY_USER:0:1}"
    query CF_DATA "Local data directory" "\$CF_BASE/data" "./data"
    query CF_STORE_NAME "Relative path used in store paths (see next queries)" "cf_store"
    query CF_STORE_LOCAL "Default local output store" "\$CF_DATA/\$CF_STORE_NAME"
    query CF_WLCG_CACHE_ROOT "Local directory for caching remote files" "" "''"
    export_and_save CF_WLCG_USE_CACHE "$( [ -z "$CF_WLCG_CACHE_ROOT" ] && echo false || echo true )"
    export_and_save CF_WLCG_CACHE_CLEANUP "${CF_WLCG_CACHE_CLEANUP:-false}"
    query CF_SOFTWARE "Local directory for installing software" "\$CF_DATA/software"
    query CF_CMSSW_BASE "Local directory for installing CMSSW" "\$CF_DATA/cmssw"
    query CF_JOB_BASE "Local directory for storing job files" "\$CF_DATA/jobs"
    query CF_LOCAL_SCHEDULER "Use a local scheduler for law tasks" "True"
    if [ "$CF_LOCAL_SCHEDULER" != "True" ]; then
        query CF_SCHEDULER_HOST "Address of a central scheduler for law tasks" "naf-cms15.desy.de"
        query CF_SCHEDULER_PORT "Port of a central scheduler for law tasks" "8082"
    else
        export_and_save CF_SCHEDULER_HOST "naf-cms14.desy.de"
        export_and_save CF_SCHEDULER_PORT "8082"
    fi
    query CF_VOMS "Virtual-organization" "cms:/cms/dcms"

    # move the env file to the correct location for later use
    if ! $setup_is_default; then
        mv "$env_file_tmp" "$env_file"
        echo -e "\nvariables written to $env_file"
    fi
}

action() {
    # Invokes the main action of this script, catches possible error codes and prints a message.

    if setup "$@"; then
        echo -e "\x1b[0;49;35mcolumnflow successfully setup\x1b[0m"
        return "0"
    else
        local code="$?"
        echo -e "\x1b[0;49;31msetup failed with code $code\x1b[0m"
        return "$code"
    fi
}
action "$@"
