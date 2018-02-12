AI container playground, get coding quickly.


Quickstart
==========

## Install rkt
```
$ gpg --recv-key 18AD5014C99EF7E3BA5F6CE950BDD3E0FC8A365E
$ wget https://github.com/rkt/rkt/releases/download/v1.29.0/rkt_1.29.0-1_amd64.deb
$ wget https://github.com/rkt/rkt/releases/download/v1.29.0/rkt_1.29.0-1_amd64.deb.asc
$ gpg --verify rkt_1.29.0-1_amd64.deb.asc
$ sudo dpkg -i rkt_1.29.0-1_amd64.deb
```

## Add yourself to the rkt groups
```
$ sudo usermod -a -G rkt,rkt-admin $USER
```

## Install build dependencies
acbuild from: https://github.com/containers/build

### cuDDN
Note that cuDDN cannot be redistributed due to its license. If you would like
to build the `cuddn-gpu.aci` or `caffe2-py*-gpu.aci` image, you will need to
download `libcuddn` and `libcuddn-dev` from https://developer.nvidia.com/cudnn
and add them to this directory. You may also need to update the `LIBCUDDN_DEB`
and `LIBCUDDN_DEV_DEB` variables in `Makefile.options` to point to the
correct filenames.

## Decide on doing a gpu or nogpu build

### With GPU (gpu)
* Download cuDNN from https://developer.nvidia.com/cudnn
* Edit `Makefile.options`, and make sure the `GPU` variable is set to `true`.
  See the above information about cuDDN dependencies.

### Without GPU (nogpu)
* Edit `Makefile.options` and set the `GPU` variable to `false`.

### Why not both?
Sure, just follow the "With GPU" guide and run `sudo make all -j4` when
building. `-j4` is optional, but fun!

## Build the images
Use sudo, since the make process will create device files and stuff, which
needs root.
```
$ sudo make
```
You might need to specify the path to acbuild:
```
$ sudo make ACBUILD=$HOME/bin/acbuild
```
If you are only interested in one environment, it is possible to build only it
(and the images leading up to it):
```
$ sudo make tensorflow
```
Note that some images (cuda, cuddn) cannot be built in a nogpu configuration,
as it does not make sense to do so.

## Run!
The `run` script will try to figure out automatically if you have a GPU
or not. If this fails, use -g or -n to force the usage of a gpu or nogpu image
respectively. The one reqired argument is which image you would like to run.
For example:
```
$ ./run tensorflow
```
Possible alternatives are:
* tensorflow
* caffe2-py2
* caffe2-py3
* cuda
* cddn

Using the newly spawned shell, you should be able to run anything you need,
including X stuff. If you want any apt installations to be persistent, update
`scripts/{tensorflow,caffe2}-{gpu,nogpu}.acbuild` to include them, and rebuild.
Alternatively, create a new `.acbuild` file under `scripts`, and add a target
in the `Makefile`. The existing files and targets should be possible to use as
a guide.


Running an app
==============
Ok, so you have built something fancy and want to run it in a container for
easier distribution. No problem. Let's say it's a hotdog classifier named
/hotdog/.

1. Copy (-r) `files/app-template` to `files/app-hotdog`
2. Edit `files/app-hotdog/entry-point` to point out what to start when the
   container starts
5. Edit `Makefile.apps`, and extend it with a recipe that can be used to build
   your app. See the `app-template.aci` example for inspiration, or look at any
   of the builds from `Makefile`.
6. `make` the app
7. Run the app: `./run -a app-hotdog.aci [ -- <extra args to rkt run> ]`

The template app
----------------
The template app will, when built, contain the example app in Facebook
Research's Detectron library (https://github.com/facebookresearch/Detectron).
To try it out as an example, make sure you have downloaded the cuDDN packages,
then run:
```
$ make app-template.aci
$ mkdir -p example-out download-cache
$ ./run -a app-template.aci -- \
        --mount=volume=out,target=/out --volume=out,kind=host,source=$(readlink -f example-out) \
        --mount=volume=cache,target=/tmp/detectron-download-cache \
        --volume=cache,kind=host,source=$(readlink -f download-cache)
```
The directory `./example-out` should now contain the demo images from the
Detectron distribution, masked and classified.

Note that this is by no means a perfectly packaged app. Among other issues, the
entire build support for CUDA/cuDDN/C/C++ applications are included. The idea
behind being able to package containers as apps using these tools is only meant
as a feature to simplify e.g. demos during development, which is why there is
no support for the rkt pod concept. When packaging your app, it is recommended
to create your own build environment, rather than using this. But feel free to
draw inspiration from these tools!


TODO
====
* Add signing support.
* Upload images (all stages?) to quay.io.
* Do not require root when building. Fakeroot might be an alternative here, but
  one of the problems is that `acbuild` spins up a container using
  `systemd-nspawn`, so it's probably tricky to have the fakeroot context active
  inside the nspawn container.
* acbuild is not actively maintained, find an alternative
