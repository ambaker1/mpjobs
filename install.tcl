package require tin 1.0
tin depend tda 0.1
set dir [tin mkdir -force mpjobs 0.1.3]
file copy LICENSE README.md pkgIndex.tcl mpjobs.tcl $dir
