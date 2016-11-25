Monitoring - DIRAC
==================

This repository aims to provide a set of Nagios probes for monitoring DIRAC instances.


Install
-------

To work correctly, the Nagios server should be setup correctly to access DIRAC, i.e. by installing [DIRAC Wiki](https://github.com/DIRACGrid/DIRAC/wiki/DIRAC-Tutorials).

Check that the installation is working:
```
# sudo -u nagios dirac-proxy-init --group biomed_user
```

Once DIRAC commands are working fine, copy the Nagios probes in the plugins directory:
```
# cp plugins/* /usr/lib64/nagios/plugins/
```
