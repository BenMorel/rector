#!/bin/bash
########################################################################
# This bash script downgrades the code to the selected PHP version
#
# Usage from within a GitHub workflow:
# .github/workflows/scripts/downgrade_packages.sh $target_php_version
# where $target_php_version is one of the following values:
# - 7.0
# - 7.1
# - 7.2
# - 7.3
# - 7.4
#
# Currently highest PHP version from which we can downgrade:
# - 8.0
#
# Eg: To downgrade to PHP 7.1, execute:
# .github/workflows/scripts/downgrade_packages.sh 7.1
########################################################################
# Variables to modify when new PHP versions are released

supported_target_php_versions=(7.0 7.1 7.2 7.3 7.4)

declare -A downgrade_php_versions=( \
    ["7.0"]="8.0 7.4 7.3 7.2 7.1" \
    ["7.1"]="8.0 7.4 7.3 7.2" \
    ["7.2"]="8.0 7.4 7.3" \
    ["7.3"]="8.0 7.4" \
    ["7.4"]="8.0" \
)
declare -A downgrade_php_whynots=( \
    ["7.0"]="7.4.* 7.3.* 7.2.* 7.1.* 7.0.*" \
    ["7.1"]="7.4.* 7.3.* 7.2.* 7.1.*" \
    ["7.2"]="7.4.* 7.3.* 7.2.*" \
    ["7.3"]="7.4.* 7.3.*" \
    ["7.4"]="7.4.*" \
)
declare -A downgrade_php_sets=( \
    ["7.0"]="downgrade-php80 downgrade-php74 downgrade-php73 downgrade-php72 downgrade-php71" \
    ["7.1"]="downgrade-php80 downgrade-php74 downgrade-php73 downgrade-php72" \
    ["7.2"]="downgrade-php80 downgrade-php74 downgrade-php73" \
    ["7.3"]="downgrade-php80 downgrade-php74" \
    ["7.4"]="downgrade-php80" \
)

########################################################################
# Helper functions
# Failure helper function (https://stackoverflow.com/a/24597941)
function fail {
    printf '%s\n' "$1" >&2  ## Send message to stderr. Exclude >&2 if you don't want it that way.
    exit "${2-1}"  ## Return a code specified by $2 or 1 by default.
}

# Print array helpers (https://stackoverflow.com/a/17841619)
function join_by { local d=$1; shift; local f=$1; shift; printf %s "$f" "${@/#/$d}"; }
########################################################################

target_php_version=$1
if [ -z "$target_php_version" ]; then
    versions=$(join_by ", " ${supported_target_php_versions[@]})
    fail "Please provide to which PHP version to downgrade to ($versions) as first argument to the bash script"
fi

# Check the version is supported
if [[ ! " ${supported_target_php_versions[@]} " =~ " ${target_php_version} " ]]; then
    versions=$(join_by ", " ${supported_target_php_versions[@]})
    fail "Version $target_php_version is not supported for downgrading. Supported versions: $versions"
fi

target_downgrade_php_versions=($(echo ${downgrade_php_versions[$target_php_version]} | tr " " "\n"))
target_downgrade_php_whynots=($(echo ${downgrade_php_whynots[$target_php_version]} | tr " " "\n"))
target_downgrade_php_sets=($(echo ${downgrade_php_sets[$target_php_version]} | tr " " "\n"))

packages_to_downgrade=()
sets_to_downgrade=()
declare -A package_paths
declare -A packages_by_set

# Switch to production
composer install --no-dev

rootPackage=$(composer info -s -N)

numberTargetPHPVersions=${#target_downgrade_php_versions[@]}
counter=1
while [ $counter -le $numberTargetPHPVersions ]
do
    pos=$(( $counter - 1 ))
    version=${target_downgrade_php_versions[$pos]}
    whynot=${target_downgrade_php_whynots[$pos]}
    set=${target_downgrade_php_sets[$pos]}
    echo Analyzing packages to downgrade from PHP version "$version"

    # Obtain the list of packages for production that need a higher version that the input one.
    # Those must be downgraded
    PACKAGES=$(composer why-not php $whynot --no-interaction | grep -o "\S*\/\S*")
    if [ -n "$PACKAGES" ]; then
        for package in $PACKAGES
        do
            echo "Enqueueing set $set on package $package"
            # Composer also analyzes the root project but its path is directly the root folder
            if [ $package = "$rootPackage" ]
            then
                path=$(pwd)
            else
                # Obtain the package's path from Composer
                # Format is "package path", so extract everything after the 1st word with cut to obtain the path
                path=$(composer info $package --path | cut -d' ' -f2-)
            fi
            packages_to_downgrade+=($package)
            sets_to_downgrade+=($set)
            package_paths[$package]=$path
            packages_by_set[$set]=$(echo "${packages_by_set[$set]} ${package}")
        done
    else
        echo No packages to downgrade
    fi
    ((counter++))
done

# Switch to dev again
composer install

# Make sure that the number of packages, paths and sets is the same
# otherwise something went wrong
numberPackages=${#packages_to_downgrade[@]}
# numberPaths=${#package_paths[@]}
# if [ ! $numberPaths -eq $numberPackages ]; then
#     fail "Number of paths ($numberPaths) and number of packages ($numberPackages) should not be different"
# fi
numberSets=${#sets_to_downgrade[@]}
if [ ! $numberSets -eq $numberPackages ]; then
    fail "Number of sets ($numberSets) and number of packages ($numberPackages) should not be different"
fi

# We must downgrade packages in the strict dependency order,
# such as sebastian/diff => symfony/event-dispatcher-contracts => psr/event-dispatcher,
# or otherwise there may be PHP error from inconsistencies (such as from a modified interface)
# To do this, have a double loop to downgrade packages,
# asking if all the "ancestors" for the package have already been downgraded,
# or let it keep iterating until next loop
# Calculate all the dependents for all packages,
# including only packages to be downgraded
echo Calculating package execution order
declare -A package_dependents
counter=1
while [ $counter -le $numberPackages ]
do
    pos=$(( $counter - 1 ))
    package_to_downgrade=${packages_to_downgrade[$pos]}
    set_to_downgrade=${sets_to_downgrade[$pos]}
    IFS=' ' read -r -a packages_to_downgrade_by_set <<< "${packages_by_set[$set_to_downgrade]}"

    dependents_to_downgrade=()
    # Obtain recursively the list of dependents, keep the first word only,
    # (which is the package name), and remove duplicates
    dependentsAsString=$(composer why "$package_to_downgrade" -r | cut -d' ' -f1 | awk '!a[$0]++' | tr "\n" " ")

    IFS=' ' read -r -a dependents <<< "$dependentsAsString"
    for dependent in "${dependents[@]}"; do
        # A package could provide itself in why (as when using "replaces"). Ignore them
        if [ $dependent = $package_to_downgrade ]; then
            continue
        fi
        # Only add the ones which must themselves be downgraded for that same set
        if [[ ! " ${packages_to_downgrade_by_set[@]} " =~ " ${dependent} " ]]; then
            continue;
        fi
        dependents_to_downgrade+=($dependent)
    done
    # The dependents are identified per package and set, because a same dependency
    # downgraded for 2 set might have dependencies downgraded for one set and not the other
    key="${package_to_downgrade}_${set_to_downgrade}"
    package_dependents[$key]=$(echo "${dependents_to_downgrade[@]}")
    echo "Dependents for package ${package_to_downgrade} and set ${set_to_downgrade}: ${dependents_to_downgrade[@]}"
    ((counter++))
done

# echo Package dependents:
# for x in "${!package_dependents[@]}"; do printf "[%s]=%s\n" "$x" "${package_dependents[$x]}" ; done

# In case of circular dependencies (eg: package1 requires package2
# and package2 requires package1), the process will fail
# hasNonDowngradedDependents=()
declare -A circular_reference_packages_by_set

echo Executing Rector to downgrade $numberDowngradedPackages packages
downgraded_packages=()
numberDowngradedPackages=1
previousNumberDowngradedPackages=1
# echo Number packages: $numberPackages
# for package in "${packages_to_downgrade[@]}"; do
#     echo Package: $package
# done
until [ $numberDowngradedPackages -gt $numberPackages ]
do
    counter=1
    while [ $counter -le $numberPackages ]
    do
        pos=$(( $counter - 1 ))
        ((counter++))
        package_to_downgrade=${packages_to_downgrade[$pos]}
        set_to_downgrade=${sets_to_downgrade[$pos]}
        key="${package_to_downgrade}_${set_to_downgrade}"
        # Check if this package has already been downgraded on a previous iteration
        if [[ " ${downgraded_packages[@]} " =~ " ${key} " ]]; then
            continue
        fi
        # Check if all dependents have already been downgraded. Otherwise, keep iterating
        hasNonDowngradedDependent=""
        IFS=' ' read -r -a dependents <<< "${package_dependents[$key]}"
        for dependent in "${dependents[@]}"; do
            dependentKey="${dependent}_${set_to_downgrade}"
            if [[ ! " ${downgraded_packages[@]} " =~ " ${dependentKey} " ]]; then
                hasNonDowngradedDependent="true"
                # hasNonDowngradedDependents+=("${dependent}=>${package_to_downgrade}")
                circular_reference_packages_by_set[${set_to_downgrade}]=$(echo "${circular_reference_packages_by_set[$set_to_downgrade]} ${dependent}")
                # echo "${package_to_downgrade} has non-downgraded dependent: ${dependentKey}"
            fi
        done
        if [ -n "${hasNonDowngradedDependent}" ]; then
            continue
        fi

        # Mark this package as downgraded
        downgraded_packages+=($key)
        ((numberDowngradedPackages++))

        path_to_downgrade=${package_paths[$package_to_downgrade]}
        # exclude=${package_excludes[$package_to_downgrade]}

        # # If there's no explicit path to exclude, set to exclude the "tests" folders
        # if [ -z $exclude ]
        # then
        #     exclude="${path_to_downgrade}/**/tests/*"
        # fi

        # If more than one path, these are split with ";". Replace with space
        path_to_downgrade=$(echo "$path_to_downgrade" | tr ";" " ")
        # exclude=$(echo "$exclude" | sed "s/;/ --exclude-path=/g")

        if [ $package_to_downgrade = "$rootPackage" ]
        then
            config=ci/downgrade/rector-downgrade-rector.php
        else
            config=ci/downgrade/rector-downgrade-dependency.php
        fi

        echo "Running set ${set_to_downgrade} for package ${package_to_downgrade} on path(s) ${path_to_downgrade}"

        # Execute the downgrade
        # Print command in output for testing
        # set -x
        # bin/rector process $path_to_downgrade --set=$set_to_downgrade --exclude-path=$exclude --target-php-version=$target_php_version --dry-run --ansi
        bin/rector process $path_to_downgrade --set=$set_to_downgrade --config=$config --ansi
        # set +x

        # If Rector fails, already exit
        if [ "$?" -gt 0 ]; then
            fail "Rector downgrade failed on set ${set_to_downgrade} for package ${package_to_downgrade}"
        fi
    done
    # If no new package was downgraded, it must be because of circular dependencies
    if [ $numberDowngradedPackages -eq $previousNumberDowngradedPackages ]
    then
        if [ ${#circular_reference_packages_by_set[@]} -eq 0 ]; then
            fail "For some unknown reason, not all packages have been downgraded"
        fi

        # Resolve all involved packages all together
        echo "Resolving circular reference packages all together"
        for set_to_downgrade in "${!circular_reference_packages_by_set[@]}";
        do
            circular_packages_to_downgrade=($(echo "${circular_reference_packages_by_set[$set_to_downgrade]}" | tr ' ' '\n' | sort -u))
            circular_paths_to_downgrade=()
            for package_to_downgrade in "${circular_packages_to_downgrade[@]}";
            do
                # Obtain the path
                circular_paths_to_downgrade+=(${package_paths[$package_to_downgrade]})

                # Mark this package as downgraded
                key="${package_to_downgrade}_${set_to_downgrade}"
                downgraded_packages+=($key)
                ((numberDowngradedPackages++))
            done

            paths_to_downgrade=$(join_by " " ${circular_paths_to_downgrade[@]})
            echo "Running set ${set_to_downgrade} for packages ${circular_packages_to_downgrade[@]}"
            config=ci/downgrade/rector-downgrade-dependency.php
            bin/rector process $paths_to_downgrade --set=$set_to_downgrade --config=$config --ansi

            # If Rector fails, already exit
            if [ "$?" -gt 0 ]; then
                fail "Rector downgrade failed on set ${set_to_downgrade} for package ${package_to_downgrade}"
            fi
        done
    fi
    # hasNonDowngradedDependents=()
    circular_reference_packages_by_set=()
    previousNumberDowngradedPackages=$numberDowngradedPackages
done