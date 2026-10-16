# External process tools are contained so the real supervisor can run safely.
loops=0
sleep(){ :; }
kill(){ if [ "$1" = -0 ]; then loops=$((loops+1)); [ "$loops" -le 3 ]; else echo SIGNAL "$@"; fi; }
pkill(){ echo SIGNAL "$@"; }
node(){ return 1; }
lsof(){
 case "$*" in
  *-sTCP:LISTEN*)
   case "$*" in *62115*) return 0;; esac
   [ "$MODE" = occupied ] && echo 9999
   return 0;;
  *-p*) if [ "$MODE" = fd ]; then /usr/bin/awk 'BEGIN {for(i=0;i<4002;i++)print i}'; fi;;
 esac
}
pgrep(){ echo 9998; }
ps(){ case "$*" in *command=*) echo 'unrelated browser';; esac; }
stat(){ if [ "$MODE" = catalog ]; then echo "$loops"; else echo 1; fi; }
curl(){
 case "$*" in
  */status*) [ "$MODE" = status ] || echo '{"upstreamPort":"62115"}';;
  */maintenance*) echo '{"released":false}';;
 esac
}
