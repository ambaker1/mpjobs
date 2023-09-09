package require tin 1.0
set version 0.1.4
set config [dict create VERSION $version]
dict set config TDA_VERSION 0.1
tin bake src/install.tin build/install.tcl $config
tin bake src/pkgIndex.tin build/pkgIndex.tcl $config
tin bake src/mpjobs.tin build/mpjobs.tcl $config
tin import assert from tin

# Run tests
cd tests
# Series tclsh
puts "Running tests in tclsh"
catch {exec tclsh test.tcl} result options
puts $result
assert [lindex [dict get $options -errorcode] end] == 1
# Series OpenSees
puts "Running tests in OpenSees"
catch {exec OpenSees test.tcl} result options
puts $result
assert [lindex [dict get $options -errorcode] end] == 1
# OpenSeesMPI, n = 1 (series)
puts "Running tests in OpenSeesMPI, n = 1"
catch {exec OpenSeesMPI -n 1 test.tcl 2>NUL} result options
puts $result
assert [lindex [dict get $options -errorcode] end] == 1
# OpenSeesMPI, n = 5 (parallel)
puts "Running tests in OpenSeesMPI, n = 5"
catch {exec OpenSeesMPI -n 5 test.tcl 2>NUL} result options
puts $result
assert [lindex [dict get $options -errorcode] end] == 1
cd ..

# Overwrite files
file copy -force {*}[glob build/*.tcl] [pwd]
tin bake doc/template/version.tin doc/template/version.tex $config
# Run installer
exec tclsh install.tcl
assert [tin installed mpjobs -exact $version] eq $version
