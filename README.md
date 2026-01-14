after ruuning the optimize_trading_vps.sh do this manually:

Open Grub: sudo nano /etc/default/grub

Find the line: GRUB_CMDLINE_LINUX_DEFAULT="..."

Add these parameters inside the quotes:

intel_idle.max_cstate=0 processor.max_cstate=1
(This prevents the CPU from going into deep sleep states C2/C3, which take microseconds to wake up from).

Update grub: sudo update-grub

Reboot.
