package require tin 0.4.5
tin depend tda 0.1
set dir [tin mkdir -force mpjobs 0.1.2]
file copy LICENSE README.md pkgIndex.tcl mpjobs.tcl $dir
