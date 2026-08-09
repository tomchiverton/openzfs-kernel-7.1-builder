#!/bin/bash
set -e

# --- Configuration ---
ZFS_VERSION="2.4.3"
WORK_DIR="$HOME/zfs-build-$$"
REPO_DIR="/var/lib/zfs-local-repo"
REPO_NAME="zfs-patched-local"

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (e.g., sudo $0)" 
   exit 1
fi

# --- Fedora Version Detection ---
FEDORA_VERSION=$(rpm -E %fedora)
echo "🔍 Detected Fedora version: $FEDORA_VERSION"

# Prepare Dependency List
DEPS=(
    git rpm-build rpmdevtools wget createrepo_c
    kernel-devel kernel-headers
    elfutils-libelf-devel zlib-devel libuuid-devel libblkid-devel
    libtirpc-devel libselinux-devel libudev-devel
    openssl-devel python3-devel python3-packaging libffi-devel python3-cffi
    lz4-devel libzstd-devel
    autoconf automake libtool
    ksh ncompress
    gcc make
    dkms sysstat perl mokutil
    libattr-devel libcurl-devel
    libaio-devel
)

# Fedora 44+ requires explicit python3-setuptools (removed from python3-devel deps)
if [[ $FEDORA_VERSION -ge 44 ]]; then
    echo "⚠️  Fedora 44+ detected: Adding explicit python3-setuptools dependency..."
    DEPS+=(python3-setuptools)
fi

# ✅ CI VALIDATION: Ensure critical dependencies are never omitted
# This prevents regressions where logic accidentally overwrites the DEPS array
CRITICAL_DEPS=("libaio-devel" "libattr-devel" "libcurl-devel" "python3-cffi")
echo "🛡️  Validating critical dependencies..."
for dep in "${CRITICAL_DEPS[@]}"; do
    if [[ ! " ${DEPS[@]} " =~ " ${dep} " ]]; then
        echo "❌ FATAL: Critical dependency '${dep}' is missing from DEPS array!"
        exit 1
    fi
done
echo "✅ All critical dependencies present."

# 1. Prepare Environment
echo "📦 Installing build dependencies..."
dnf install -y "${DEPS[@]}"

echo "🚀 Starting OpenZFS $ZFS_VERSION build for Kernel 7.1.x..."

mkdir -p "$WORK_DIR" "$REPO_DIR"
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# 2. Download Official Source
cd "$WORK_DIR"
echo "📥 Downloading official source..."
wget -q "https://github.com/openzfs/zfs/releases/download/zfs-${ZFS_VERSION}/zfs-${ZFS_VERSION}.tar.gz"

# 3. Prepare RPM Build Environment
echo "🔧 Preparing source for RPM build..."
cp "zfs-${ZFS_VERSION}.tar.gz" ~/rpmbuild/SOURCES/

# ... (After copying tarball to SOURCES) ...

# CRITICAL FIX: Patch the source tree that rpmbuild will use
# This ensures the INSTALLED source in /usr/src/ has the correct META file
echo "   - Patching source tree for RPM build..."
cd ~/rpmbuild/SOURCES
tar xzf zfs-${ZFS_VERSION}.tar.gz
cd zfs-${ZFS_VERSION}

# Initialize a temporary git repo to allow 'git apply' (cleaner than 'patch')
git init -q
# Set local dummy identity to avoid "Author identity unknown" errors on fresh systems
git config user.email "builder@localhost"
git config user.name "OpenZFS Builder"
git add -A
git commit -q -m "Initial upstream source"

# 4. Apply OFFICIAL Kernel 7.1 META fix (Commit a35e8d8)
# Replaces manual sed with the exact upstream change signed by maintainers
echo "   - Backporting official META fix for Linux 7.1 (Commit a35e8d8)..."
if ! curl -sSL "https://github.com/openzfs/zfs/commit/a35e8d8.patch" | git apply -; then
    echo "   - ❌ ERROR: Failed to apply official META patch."
    exit 1
fi
echo "   - ✅ Official META patch applied."

# 5. Apply the REAL fix for Issue #18787 (mmap read underflow)
# Backports commit 223b8bc using git apply for atomic safety
echo "   - Backporting upstream fix for Issue #18787 (zfs_fillpage underflow)..."
if ! curl -sSL "https://github.com/openzfs/zfs/commit/223b8bc.patch" | git apply -; then
    echo "   - ❌ ERROR: Failed to apply Issue #18787 fix."
    exit 1
fi
echo "   - ✅ Issue #18787 fix applied."

# Cleanup temporary git data (optional, keeps source tree clean for rpmbuild)
rm -rf .git

echo "   - ✅ Source tree successfully patched with upstream commits."   

# Re-pack the tarball so rpmbuild uses the patched version
cd ..
tar czf zfs-${ZFS_VERSION}.tar.gz zfs-${ZFS_VERSION}
rm -rf zfs-${ZFS_VERSION}

echo "   - Source tarball patched and repacked."   

# 6. Extract the NOW-PATCHED tarball to run configure and generate dkms.conf
# We extract from the patched SOURCES tarball, not the original WORK_DIR one
cd "$WORK_DIR"
tar xzf ~/rpmbuild/SOURCES/zfs-${ZFS_VERSION}.tar.gz
cd "zfs-${ZFS_VERSION}"

# 7. Run configure to generate spec files and Makefiles
echo "⚙️ Running configure..."
./configure --with-spec=redhat --without-libunwind

# 8. Copy the generated spec file
if [ -f rpm/redhat/zfs.spec ]; then
    cp rpm/redhat/zfs.spec ~/rpmbuild/SPECS/
elif [ -f rpm/generic/zfs.spec ]; then
    cp rpm/generic/zfs.spec ~/rpmbuild/SPECS/
else
    echo "❌ zfs.spec not found after configure"
    exit 1
fi

# 9. Patch the SPEC file
echo "   - Patching zfs.spec..."
SPEC_FILE="$HOME/rpmbuild/SPECS/zfs.spec"

# 10. Inject changelog entry (Required for Fedora 44, clean for 43)
# Appends a standard entry to satisfy %source_date_epoch_from_changelog
if grep -q "^%changelog" "$SPEC_FILE"; then
    sed -i '/^%changelog/a * Mon Aug 03 2026 Automated Build <builder@localhost> - '"$ZFS_VERSION"'-1\n- Automated build for Kernel 7.1.x (Backports: a35e8d8, 223b8bc)' "$SPEC_FILE"
    echo "   - Injected changelog entry for reproducible builds."
else
    echo "   - ⚠️ Warning: %changelog section not found in spec file."
fi

echo "✅ Section 3 Complete. Ready to build."

# 11. CRITICAL: Generate dkms.conf
echo "   - Generating module/dkms.conf..."

# Ensure we are in the source root for relative paths to work correctly
cd "$WORK_DIR/zfs-${ZFS_VERSION}"

# Run mkconf with explicit arguments
./scripts/dkms.mkconf \
    -n zfs \
    -v "${ZFS_VERSION}" \
    -c META \
    -f module/dkms.conf

# Verify success
if [ ! -s module/dkms.conf ] || ! grep -q "PACKAGE_NAME=" module/dkms.conf; then
    echo "❌ FAILED: module/dkms.conf is empty or invalid."
    cat module/dkms.conf
    exit 1
fi

echo "   - dkms.conf generated successfully."   

# 12. Build User-Space RPMs
echo "🏗️ Building user-space RPMs..."
rm -rf ~/rpmbuild/BUILD/zfs-*

rpmbuild -bb ~/rpmbuild/SPECS/zfs.spec \
    --define "with_utils 1" \
    --define "_topdir $HOME/rpmbuild" \
    --nodeps

if [ $? -ne 0 ]; then
    echo "❌ User-space RPM build failed."
    exit 1
fi

# 13. Build the DKMS RPM specifically
echo "🏗️ Building zfs-dkms RPM..."

# Locate the generated dkms spec file
if [ -f rpm/redhat/zfs-dkms.spec ]; then
    DKMS_SPEC="rpm/redhat/zfs-dkms.spec"
elif [ -f rpm/generic/zfs-dkms.spec ]; then
    DKMS_SPEC="rpm/generic/zfs-dkms.spec"
else
    echo "❌ zfs-dkms.spec not found. DKMS support not enabled in configure."
    exit 1
fi

# Copy to SPECS dir (overwrite if exists)
cp "$DKMS_SPEC" ~/rpmbuild/SPECS/zfs-dkms.spec

# CRITICAL: Ensure the source tarball is in SOURCES for the dkms build
# The dkms spec expects to unpack the source to /usr/src/zfs-<version>
if [ ! -f ~/rpmbuild/SOURCES/zfs-${ZFS_VERSION}.tar.gz ]; then
    cp "$WORK_DIR/zfs-${ZFS_VERSION}.tar.gz" ~/rpmbuild/SOURCES/
fi

# Build the DKMS RPM
rpmbuild -bb ~/rpmbuild/SPECS/zfs-dkms.spec \
    --define "_topdir $HOME/rpmbuild" \
    --nodeps

if [ $? -ne 0 ]; then
    echo "❌ zfs-dkms RPM build failed."
    exit 1
fi

# 14. Verify and Locate DKMS RPM
echo "🔍 Locating generated RPMs..."

# CRITICAL: zfs-dkms is a noarch package.
DKMS_RPM=$(ls ~/rpmbuild/RPMS/noarch/zfs-dkms-${ZFS_VERSION}-*.noarch.rpm 2>/dev/null | head -n 1)

if [ -z "$DKMS_RPM" ]; then
    echo "❌ zfs-dkms RPM not found in noarch directory."
    echo "   --- Contents of ~/rpmbuild/RPMS/noarch/ ---"
    ls -lh ~/rpmbuild/RPMS/noarch/ 2>/dev/null || echo "   (Directory empty or missing)"
    exit 1
fi

echo "✅ Successfully built: $DKMS_RPM"
echo "   --- All Generated RPMs ---"
find ~/rpmbuild/RPMS -name "*.rpm" -type f

# 15. Create Local Repo
echo "📦 Setting up local DNF repository..."
mkdir -p "$REPO_DIR"
cp ~/rpmbuild/RPMS/x86_64/*.rpm "$REPO_DIR/"
cp ~/rpmbuild/RPMS/noarch/*.rpm "$REPO_DIR/"
createrepo_c "$REPO_DIR"

# 16. Configure DNF Priority
echo "⚙️ Configuring DNF priority..."
cat > /etc/yum.repos.d/${REPO_NAME}.repo <<EOF
[${REPO_NAME}]
name=Local Patched OpenZFS (Kernel 7.1 Support)
baseurl=file://${REPO_DIR}
enabled=1
gpgcheck=0
priority=10
EOF

# Cleanup
cd ..
rm -rf "$WORK_DIR" 

echo "✅ SUCCESS!"
echo "   - Repository created at: $REPO_DIR"
echo "   - DNF config: /etc/yum.repos.d/${REPO_NAME}.repo"
echo ""
echo "Next steps:"
echo "   1. Remove old ZFS and dependencies: dnf remove zfs zfs-dkms zfs-dracut libnvpair* libuutil* libzfs* libzpool* --setopt protected_packages="
echo "   2. Install from local repo (pulls isolated dependencies): dnf install zfs zfs-dkms zfs-dracut --repo=${REPO_NAME}"
