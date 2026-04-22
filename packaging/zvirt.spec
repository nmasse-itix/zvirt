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

BuildArch:      noarch

Requires:       bash
Requires:       libvirt
Requires:       zfs
BuildRequires:  make
BuildRequires:  python3-pip

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
pip install --target %{buildroot}%{python3_sitelib} foo-package

%files
%{_bindir}/libvirt-hook
%{_bindir}/snapshot-libvirt-domains

%changelog
* Mon Nov 24 2025 Nicolas Massé <nicolas.masse@itix.fr> - 0.0.1-1
- Initial package release
