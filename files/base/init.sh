#!/bin/sh

# Fix permissions
chmod 1777 /tmp/ /var/run/ /run/

# Fix hostname
if ! grep -q " localhost " /etc/hosts; then
  echo "127.0.0.1 localhost localhost.localdomain" >> /etc/hosts
fi
if ! grep -q "[[:space:]]$(hostname -s)$" /etc/hosts; then
  echo "127.0.1.1 $(hostname -f) $(hostname -s)" >> /etc/hosts
fi

if [ "$CONTAINER_DEV" ]; then
  if [ -n "$CONTAINER_USER" ] && [ -n "$CONTAINER_UID" ] && [ -n "$CONTAINER_HOME" ]; then
    # Create user
    useradd -d $CONTAINER_HOME -u $CONTAINER_UID -G cwheel $CONTAINER_USER
  else
    echo "Warning: \$CONTAINER_* variables not all set, logging in as root" >&2
    CONTAINER_USER=root
  fi
else
    useradd -m -u 1000 user
    export CONTAINER_USER=user
fi

# Run subsequent init scripts
for file in $(ls -1 /init.d/* 2> /dev/null | sort); do
  . $file
done

if [ "$CONTAINER_DEV" ]; then
  # -p == Do not clob environment
  # -f user == Force-login as user
  exec /bin/login -p -f $CONTAINER_USER
elif [ -x "/entry-point" ]; then
  exec su -c '/entry-point' user
else
  echo "Not started in development mode, and /entry-point non-existing. Exiting..." >&2
fi
