%global __brp_python_bytecompile %{nil}
Name:           zvirt
Version:        0.0.5
%if %{defined dist}
Release:        1%{?dist}
%else
Release:        1
%endif
Summary:        Libvirt ZFS snapshots utility

License:        MIT
URL:            https://github.com/nmasse-itix/zvirt
Source0:        %{name}-%{version}.tar.gz
Source1:        zfs_autobackup-3.3-py3-none-any.whl

BuildArch:      noarch

Requires:       bash
Requires:       libvirt
Requires:       zfs
Requires:       python3-colorama
BuildRequires:  make
BuildRequires:  python3-pip
BuildRequires:  python3-rpm-macros
BuildRequires:  python3-colorama

%description
Zvirt takes snapshots of Libvirt domains using ZFS.
It supports both crash-consistent and live snapshots.

At the end, all components of a domain (Domain definition, TPM, NVRAM, 
VirtioFS, ZFS snapshots of the underlying storage volumes) are captured 
as a set of consistent ZFS snapshots.

It is implemented as a set of hooks for the zfs_autobackup script.

%prep
%setup -q

%build
# Nothing to build for a shell script

%install
make PREFIX=%{buildroot}%{_prefix} install
pip install --root %{buildroot} --prefix %{_prefix} --no-compile --no-deps --no-index --ignore-installed --find-links %{_sourcedir} zfs-autobackup

%files
%{_bindir}/libvirt-hook
%{_bindir}/snapshot-libvirt-domains
%{_bindir}/zfs-autobackup
%{_bindir}/zfs-autoverify
%{_bindir}/zfs-check
%{python3_sitelib}/zfs_autobackup/
%{python3_sitelib}/zfs_autobackup-*.dist-info/

%changelog
* Wed Apr 22 2026 Nicolas Massé <nicolas.masse@itix.fr> - 0.0.6-1
- Switch to zfs-autobackup + hooks

* Mon Nov 24 2025 Nicolas Massé <nicolas.masse@itix.fr> - 0.0.1-1
- Initial package release
