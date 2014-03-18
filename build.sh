#!/usr/bin/env bash
#
# Copyright 2010-2013 Tasos Laskos <tasos.laskos@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# Experimental Arachni install script, it's supposed to take care of everything
# including system library dependencies, Ruby, gem dependencies and Arachni itself.
#
# Credits:
#     Tasos Laskos <tasos.laskos@gmail.com> -- Original Linux version
#     Edwin van Andel <evanandel@yafsec.com> -- Patches for *BSD and testing
#     Dan Woodruff <daniel.woodruff@gmail.com> -- Patches for OSX and testing
#

source `dirname $0`/lib/setenv.sh

cat<<EOF

               Arachni builder (experimental)
            ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

 It will create an environment, download and install all dependencies in it,
 configure it and install Arachni itself in it.

     by Tasos Laskos <tasos.laskos@gmail.com>
-------------------------------------------------------------------------

EOF

if [[ "$1" == '-h' ]] || [[ "$1" == '--help' ]]; then
    cat <<EOF
Usage: $0 [build directory]

Build directory defaults to 'arachni'.

If at any point you decide to cancel the process, re-running the script
will continue from the point it left off.

EOF
    exit
fi

echo
echo "# Checking for script dependencies"
echo '----------------------------------------'
deps="
    wget
    gcc
    g++
    awk
    sed
    grep
    make
    expr
    perl
    tar
    git
    python
"
for dep in $deps; do
    echo -n "  * $dep"
    if [[ ! `which "$dep"` ]]; then
        echo " -- FAIL"
        fail=true
    else
        echo " -- OK"
    fi
done

if [[ $fail ]]; then
    echo "Please install the missing dependencies and try again."
    exit 1
fi

echo
echo "---- Building branch/tag: `branch`"

arachni_tarball_url=`tarball_url`

#
# All system library dependencies in proper installation order.
#
libs=(
    http://zlib.net/zlib-1.2.8.tar.gz
    http://www.openssl.org/source/openssl-1.0.1e.tar.gz
    http://www.sqlite.org/2013/sqlite-autoconf-3071700.tar.gz
    ftp://xmlsoft.org/libxml2/libxml2-2.8.0.tar.gz
    ftp://xmlsoft.org/libxslt/libxslt-1.1.28.tar.gz
    http://curl.haxx.se/download/curl-7.28.1.tar.gz
    http://pyyaml.org/download/libyaml/yaml-0.1.4.tar.gz
    http://ftp.postgresql.org/pub/source/v9.2.4/postgresql-9.2.4.tar.gz
    http://ftp.ruby-lang.org/pub/ruby/1.9/ruby-1.9.3-p448.tar.gz
)

#
# The script will look for the existence of files whose name begins with the
# following strings to see if a lib has already been installed.
#
# Their order should correspond to the entries in the 'libs' array.
#
libs_so=(
    libz
    libssl
    libsqlite3
    libxml2
    libxslt
    libcurl
    libyaml-0
    postgresql
    ruby
)

if [[ ! -z "$1" ]]; then
    # root path
    root="$1"
else
    # root path
    root="arachni"
fi

clean_build="arachni-clean"
if [[ -d $clean_build ]]; then

    echo
    echo "==== Found backed up clean build ($clean_build), using it as base."

    rm -rf $root
    cp -R $clean_build $root
else
    mkdir -p $root
fi

update_clean_dir=false

# Directory of this script.
scriptdir=`readlink_f $0`

# Root or the package.
root=`readlink_f $root`

# Holds a base system dir layout where the dependencies will be installed.
system_path="$root/system"

# Build directories holding downloaded archives, sources, build logs, etc.
build_path="$root/build"

# Holds tarball archives.
archives_path="$build_path/archives"

# Holds extracted source archives.
src_path="$build_path/src"

# Keeps logs of STDERR and STDOUT for the build/install operations.
logs_path="$build_path/logs"

# --prefix value for 'configure' scripts
configure_prefix="$system_path/usr"
usr_path=$configure_prefix

# Gem storage directories
gem_home="$system_path/gems"
gem_path=$gem_home


#
# Special config for packages that need something extra.
# These are called dynamically using the obvious naming convention.
#
# For some reason assoc arrays don't work...
#

configure_postgresql="./configure --without-readline \
--with-includes=$configure_prefix/include \
--with-libraries=$configure_prefix/lib \
--bindir=$build_path/tmp"

configure_libxslt="./configure --with-libxml-prefix=$configure_prefix"

configure_libxml2="./configure --without-python"

configure_ruby="./configure --with-opt-dir=$configure_prefix \
--with-libyaml-dir=$configure_prefix \
--with-zlib-dir=$configure_prefix \
--with-openssl-dir=$configure_prefix \
--disable-install-doc --enable-shared"

common_configure_openssl="-I$usr_path/include -L$usr_path/lib \
zlib no-asm no-krb5 shared"

if [[ "Darwin" == "$(uname)" ]]; then

    hw_machine=$(sysctl hw.machine | awk -F: '{print $2}' | sed 's/^ //')
    hw_cpu64bit=$(sysctl hw.cpu64bit_capable | awk '{print $2}')

    if [[ "Power Macintosh" == "$hw_machine" ]] ; then
        if [[ $hw_cpu64bit == 1 ]]; then
            openssl_os="darwin64-ppc-cc"
        else
            openssl_os="darwin-ppc-cc"
        fi
    else
        if [[ $hw_cpu64bit == 1 ]]; then
            openssl_os="darwin64-x86_64-cc"
        else
            openssl_os="darwin-i386-cc"
        fi
    fi
    configure_openssl="./Configure $openssl_os $common_configure_openssl"
else
    configure_openssl="./config $common_configure_openssl"
fi

configure_curl="./configure \
--with-ssl=$usr_path \
--with-zlib=$usr_path \
--without-librtmp \
--enable-optimize \
--enable-nonblocking \
--enable-threaded-resolver \
--enable-crypto-auth \
--enable-cookies \
--enable-http \
--disable-file \
--disable-ftp \
--disable-ldap \
--disable-ldaps \
--disable-rtsp \
--disable-dict \
--disable-telnet \
--disable-tftp \
--disable-pop3 \
--disable-imap \
--disable-smtp \
--disable-gopher \
--disable-rtmp \
--disable-cookies"

orig_path=$PATH

#
# Creates the directory structure for the self-contained package.
#
setup_dirs( ) {
    cd $root

    dirs="
        $build_path/logs
        $build_path/archives
        $build_path/src
        $build_path/tmp
        $root/bin
        $system_path/logs/framework
        $system_path/logs/webui
        $system_path/gems
        $system_path/usr/bin
        $system_path/usr/include
        $system_path/usr/info
        $system_path/usr/lib
        $system_path/usr/man
    "
    for dir in $dirs
    do
        echo -n "  * $dir"
        if [[ ! -s $dir ]]; then
            echo
            mkdir -p $dir
        else
            echo " -- already exists."
        fi
    done

    cd - > /dev/null
}

#
# Checks the last return value and exits with an error message on failure.
#
# To be called after each step.
#
handle_failure(){
    rc=$?
    if [[ $rc != 0 ]] ; then
        echo "Build failed, check $logs_path/$1 for details."
        echo "When you resolve the issue you can run the script again to continue where the process left off."
        exit $rc
    fi
}

#
# Downloads the given URL and displays an auto-refreshable progress %.
#
download() {
    echo -n "  * Downloading $1"
    echo -n " -  0% ETA:      -s"
    wget -c --progress=dot --no-check-certificate $1 $2 2>&1 | \
        while read line; do
            echo $line | grep "%" | sed -e "s/\.//g" | \
            awk '{printf("\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b%4s ETA: %6s", $2, $4)}'
        done

    echo -e "\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b                           "
}

#
# Downloads an archive (by URL) and places it under $archives_path.
#
# Calls handle_failure afterwards.
#
download_archive() {
    cd $archives_path

    download $1
    handle_failure $2

    cd - > /dev/null
}

#
# Extracts an archive (by name) under $src_path.
#
extract_archive() {
    if [ -z "$2" ]; then
        dir=$src_path
    else
        dir=$2
    fi

    echo "  * Extracting"
    tar xvf $archives_path/$1*.tar.gz -C $dir 2>> $logs_path/$1 1>> $logs_path/$1
    handle_failure $1
}

#
# Installs an extracted archive which is in $src_path, by name.
#
install_from_src() {
    cd $src_path/$1-*

    echo "  * Cleaning"
    make clean 2>> $logs_path/$1 1>> $logs_path/$1

    eval special_config=\$$"configure_$1"
    if [[ $special_config ]]; then
        configure=$special_config
    else
        configure="./configure"
    fi

    configure="${configure} --prefix=$configure_prefix"

    echo "  * Configuring ($configure)"
    echo "Configuring with: $configure" 2>> $logs_path/$1 1>> $logs_path/$1

    $configure 2>> $logs_path/$1 1>> $logs_path/$1
    handle_failure $1

    echo "  * Compiling"
    make 2>> $logs_path/$1 1>> $logs_path/$1
    handle_failure $1

    echo "  * Installing"
    #If OpenSSL install without man. Fixes perl/podman errors on man generation.
    if [[ $1 = "openssl" ]]; then
        make install_sw 2>> $logs_path/$1 1>> $logs_path/$1
        handle_failure $1
    else
        make install 2>> $logs_path/$1 1>> $logs_path/$1
    fi

    handle_failure $1
    cd - > /dev/null
}

#
# Gets the name of the given file/directory/URL.
#
get_name(){
    basename $1 | awk -F- '{print $1}'
}

#
# Downloads and install a package by URL.
#
download_and_install() {
    name=`get_name $1`

    download_archive $1 $name
    extract_archive $name
    install_from_src $name
    echo
}

#
# Downloads and installs all $libs.
#
install_libs() {
    libtotal=${#libs[@]}

    for (( i=0; i<$libtotal; i++ )); do
        so=${libs_so[$i]}
        lib=${libs[$i]}
        idx=`expr $i + 1`

        echo "## ($idx/$libtotal) `get_name $lib`"

        so_files="$usr_path/lib/$so"*
        ls  $so_files &> /dev/null
        if [[ $? == 0 ]] ; then
            echo "  * Already installed, found:"
            for so_file in `ls $so_files`; do
                echo "    o $so_file"
            done
            echo
        else
            update_clean_dir=true
            download_and_install $lib
        fi
    done

}

#
# Returns Bash environment configuration.
#
get_ruby_environment() {

    cd "$usr_path/lib/ruby/1.9.1/"

    possible_arch_dir=$(echo `uname -p`*)
    if [[ -d "$possible_arch_dir" ]]; then
        arch_dir=$possible_arch_dir
    fi

    # The running process could be in 32bit compat mode on a 64bit system but
    # Ruby will end up being compiled for 64bit nonetheless so we need to check
    # for that and remedy the situation.
    possible_arch_dir=$(echo x86_64*)
    if [[ -d "$possible_arch_dir" ]]; then
        arch_dir=$possible_arch_dir
    fi

    if [[ -d "$arch_dir" ]]; then
        platform_lib=":\$MY_RUBY_HOME/1.9.1/$arch_dir:\$MY_RUBY_HOME/site_ruby/1.9.1/$arch_dir"
    fi

    cat<<EOF
#
# Environment configuration.
#
# Makes bundled dependencies available before running anything Arachni related.
#
# *DO NOT EDIT* unless you really, really know what you're doing.
#

#
# \$env_root is set by the caller.
#

echo "\$LD_LIBRARY_PATH-\$DYLD_LIBRARY_PATH" | egrep \$env_root > /dev/null
if [[ \$? -ne 0 ]] ; then
    export PATH; PATH="\$env_root/../bin:\$env_root/usr/bin:\$env_root/gems/bin:\$PATH"
    export LD_LIBRARY_PATH; LD_LIBRARY_PATH="\$env_root/usr/lib"
    export DYLD_LIBRARY_PATH; DYLD_LIBRARY_PATH="\$env_root/usr/lib:\$DYLD_LIBRARY_PATH"
fi

export RUBY_VERSION; RUBY_VERSION='ruby-1.9.3-p448'
export GEM_HOME; GEM_HOME="\$env_root/gems"
export GEM_PATH; GEM_PATH="\$env_root/gems"
export MY_RUBY_HOME; MY_RUBY_HOME="\$env_root/usr/lib/ruby"
export RUBYLIB; RUBYLIB=\$MY_RUBY_HOME:\$MY_RUBY_HOME/site_ruby/1.9.1:\$MY_RUBY_HOME/1.9.1$platform_lib
export IRBRC; IRBRC="\$env_root/usr/lib/ruby/.irbrc"

# Arachni packages run the system in production.
export RAILS_ENV=production

export ARACHNI_FRAMEWORK_LOGDIR="\$env_root/logs/framework"
export ARACHNI_WEBUI_LOGDIR="\$env_root/logs/webui"

export NOKOGIRI_USE_SYSTEM_LIBRARIES=true

EOF
}

get_setenv() {
    cat<<EOF
#!/usr/bin/env bash

env_root="\$(dirname \${BASH_SOURCE[0]})"
if [[ -s "\$env_root/environment" ]]; then
    source "\$env_root/environment"
else
    echo "ERROR: Missing environment file: '\$env_root/environment" >&2
    exit 1
fi

EOF
}

#
# Provides a wrapper for executables, it basically sets all relevant
# env variables before calling the executable in question.
#
get_wrapper_environment() {
    cat<<EOF
#!/usr/bin/env bash

source "\$(dirname \$0)/readlink_f.sh"
source "\$(dirname "\$(readlink_f "\${0}")")"/../system/setenv
exec $1
fi

EOF
}

get_wrapper_template() {
    get_wrapper_environment "ruby $1 \"\$@\""
}

get_server_script() {
    get_wrapper_environment '$GEM_PATH/bin/rackup $env_root/arachni-ui-web/config.ru  "$@"'
}

get_rake_script() {
    get_wrapper_environment '$GEM_PATH/bin/rake -f $env_root/arachni-ui-web/Rakefile "$@"'
}

get_shell_script() {
    get_wrapper_environment '; export PS1="arachni-shell\$ "; bash --noprofile --norc "$@"'
}

#
# Sets the environment, updates rubygems and installs vital gems
#
prepare_ruby() {
    export env_root=$system_path

    echo "  * Generating environment configuration ($env_root/environment)"
    get_ruby_environment > $env_root/environment
    source $env_root/environment

    $usr_path/bin/gem source -r https://rubygems.org/ > /dev/null
    $usr_path/bin/gem source -a http://rubygems.org/ > /dev/null

    echo "  * Installing sys-proctable"
    download "https://github.com/djberg96/sys-proctable/tarball/master" "-O $archives_path/sys-proctable-pkg.tar.gz" &> /dev/null
    extract_archive "sys-proctable" &> /dev/null

    cd $src_path/*-sys-proctable*

    $usr_path/bin/rake install --trace 2>> "$logs_path/sys-proctable" 1>> "$logs_path/sys-proctable"
    handle_failure "sys-proctable"
    $usr_path/bin/gem build sys-proctable.gemspec 2>> "$logs_path/sys-proctable" 1>> "$logs_path/sys-proctable"
    handle_failure "sys-proctable"
    $usr_path/bin/gem install sys-proctable-*.gem 2>> "$logs_path/sys-proctable" 1>> "$logs_path/sys-proctable"
    handle_failure "sys-proctable"

    echo "  * Updating Rubygems"
    $usr_path/bin/gem update --system 2>> "$logs_path/rubygems" 1>> "$logs_path/rubygems"
    handle_failure "rubygems"

    echo "  * Installing Bundler"
    $usr_path/bin/gem install bundler --no-ri  --no-rdoc  2>> "$logs_path/bundler" 1>> "$logs_path/bundler"
    handle_failure "bundler"
}

#
# Installs the Arachni Web User Interface which in turn pulls in the Framework
# as a dependency, that way we kill two birds with one package.
#
install_arachni() {

    # The Arachni Web interface archive needs to be stored under $system_path
    # because it needs to be preserved, it is our app after all.
    rm "$archives_path/arachni-ui-web.tar.gz" &> /dev/null
    download $arachni_tarball_url "-O $archives_path/arachni-ui-web.tar.gz"
    handle_failure "arachni-ui-web"
    extract_archive "arachni-ui-web" $system_path

    # GitHub may append the git ref or branch to the folder name, strip it.
    mv $system_path/arachni-ui-web* $system_path/arachni-ui-web
    cd $system_path/arachni-ui-web

    echo "  * Installing"

    # Install the Rails bundle *with* binstubs because we'll need to symlink
    # them from the package executables under $root/bin/.
    $gem_path/bin/bundle install --binstubs 2>> "$logs_path/arachni-ui-web" 1>> "$logs_path/arachni-ui-web"
    handle_failure "arachni-ui-web"

    echo "  * Precompiling assets"
    $gem_path/bin/rake assets:precompile 2>> "$logs_path/arachni-ui-web" 1>> "$logs_path/arachni-ui-web"
    handle_failure "arachni-ui-web"

    echo "  * Setting-up the database"
    $gem_path/bin/rake db:migrate 2>> "$logs_path/arachni-ui-web" 1>> "$logs_path/arachni-ui-web"
    handle_failure "arachni-ui-web"
    $gem_path/bin/rake db:setup 2>> "$logs_path/arachni-ui-web" 1>> "$logs_path/arachni-ui-web"
    handle_failure "arachni-ui-web"

    echo "  * Writing full version to VERSION file"

    # Needed by build_and_package.sh to figure out the release version and it's
    # nice to have anyways.
    $gem_path/bin/rake version:full > "$root/VERSION"
    handle_failure "arachni-ui-web"
}

install_bin_wrappers() {
    cp "`dirname $(readlink_f $scriptdir)`/lib/readlink_f.sh" "$root/bin/"

    get_setenv > "$root/system/setenv"
    chmod +x "$root/system/setenv"

    get_wrapper_template "\$env_root/arachni-ui-web/script/create_user" > "$root/bin/arachni_web_create_user"
    chmod +x "$root/bin/arachni_web_create_user"
    echo "  * $root/bin/arachni_web_create_user"

    get_wrapper_template "\$env_root/arachni-ui-web/script/change_password" > "$root/bin/arachni_web_change_password"
    chmod +x "$root/bin/arachni_web_change_password"
    echo "  * $root/bin/arachni_web_change_password"

    get_wrapper_template "\$env_root/arachni-ui-web/script/import" > "$root/bin/arachni_web_import"
    chmod +x "$root/bin/arachni_web_import"
    echo "  * $root/bin/arachni_web_import"

    get_server_script > "$root/bin/arachni_web"
    chmod +x "$root/bin/arachni_web"
    echo "  * $root/bin/arachni_web"

    get_rake_script > "$root/bin/arachni_web_task"
    chmod +x "$root/bin/arachni_web_task"
    echo "  * $root/bin/arachni_web_task"

    get_shell_script > "$root/bin/arachni_shell"
    chmod +x "$root/bin/arachni_shell"
    echo "  * $root/bin/arachni_shell"

    cd $env_root/arachni-ui-web/bin
    for bin in arachni*; do
        echo "  * $root/bin/$bin => $env_root/arachni-ui-web/bin/$bin"
        get_wrapper_template "\$env_root/arachni-ui-web/bin/$bin" > "$root/bin/$bin"
        chmod +x "$root/bin/$bin"
    done
    cd - > /dev/null
}

echo
echo '# (1/5) Creating directories'
echo '---------------------------------'
setup_dirs

echo
echo '# (2/5) Installing dependencies'
echo '-----------------------------------'
install_libs

if [[ ! -d $clean_build ]] || [[ $update_clean_dir == true ]]; then
    mkdir -p $clean_build/system/
    echo "==== Backing up clean build directory ($clean_build)."
    cp -R $usr_path $clean_build/system/
fi

echo
echo '# (3/5) Preparing the Ruby environment'
echo '-------------------------------------------'
prepare_ruby

echo
echo '# (4/5) Installing Arachni'
echo '-------------------------------'
install_arachni

echo
echo '# (5/5) Installing bin wrappers'
echo '------------------------------------'
install_bin_wrappers

echo
echo '# Cleaning up'
echo '----------------'
echo "  * Removing build resources"
rm -rf $build_path

if [[ environment == 'development' ]]; then
    echo "  * Removing development headers"
    rm -rf $usr_path/include/*
fi

echo "  * Removing docs"
rm -rf $usr_path/share/*
rm -rf $gem_path/doc/*

echo "  * Clearing GEM cache"
rm -rf $gem_path/cache/*

cp `dirname $scriptdir`/templates/README.tpl $root/README
cp `dirname $scriptdir`/templates/LICENSE.tpl $root/LICENSE
cp `dirname $scriptdir`/templates/TROUBLESHOOTING.tpl $root/TROUBLESHOOTING

echo "  * Adjusting shebangs"
if [[ `uname` == "Darwin" ]]; then
    find $env_root/ -type f -exec sed -i '' 's/#!\/.*\/ruby/#!\/usr\/bin\/env ruby/g' {} \;
else
    find $env_root/ -type f -exec sed -i 's/#!\/.*\/ruby/#!\/usr\/bin\/env ruby/g' {} \;
fi

echo
cat<<EOF
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Build completed successfully!

You can add '$root/bin' to your path in order to be able to access the Arachni
executables from anywhere:

    echo 'export PATH=$root/bin:\$PATH' >> ~/.bash_profile
    source ~/.bash_profile

Useful resources:
    * Homepage           - http://arachni-scanner.com
    * Blog               - http://arachni-scanner.com/blog
    * Documentation      - http://arachni-scanner.com/wiki
    * Support            - http://support.arachni-scanner.com
    * GitHub page        - http://github.com/Arachni/arachni
    * Code Documentation - http://rubydoc.info/github/Arachni/arachni
    * Author             - Tasos "Zapotek" Laskos (http://twitter.com/Zap0tek)
    * Twitter            - http://twitter.com/ArachniScanner
    * Copyright          - 2010-2014 Tasos Laskos
    * License            - Apache License v2

Have fun ;)

Cheers,
The Arachni team.

EOF
