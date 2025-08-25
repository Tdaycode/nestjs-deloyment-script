# Backend monitoring script for tday

echo "=== tday Backend Status ==="
echo ""

echo "PM2 Process Status:"
pm2 show tday-backend

echo ""
echo "Recent Logs:"
pm2 logs tday-backend --lines 20

echo ""
echo "System Resources:"
echo "Memory Usage:"
free -h

echo ""
echo "Disk Usage:"
df -h

echo ""
echo "API Health Check:"
curl -s https://tday.scholarscoven.com/health || echo "Health check failed"

echo ""
echo "Nginx Status:"
sudo systemctl status nginx --no-pager -l

echo ""
echo "SSL Certificate Status:"
sudo certbot certificates | grep -A 2 "tday.scholarscoven.com"