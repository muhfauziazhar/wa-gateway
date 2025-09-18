# WhatsApp Gateway VPS Deployment Guide

## 🚀 VPS Setup Requirements

### Minimum Specs:
- **RAM**: 2GB+
- **Storage**: 10GB+ SSD
- **CPU**: 2 vCPU
- **OS**: Ubuntu 20.04/22.04 LTS

## 📋 Installation Steps

### 1. Server Preparation
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Node.js 18+
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install PM2
sudo npm install -g pm2

# Install Nginx
sudo apt install nginx -y
```

### 2. Project Setup
```bash
# Clone repository
git clone https://github.com/mimamch/wa-gateway.git
cd wa-gateway

# Install dependencies
npm ci --only=production

# Create environment file
cp .env.example .env
```

### 3. Environment Configuration
```env
NODE_ENV=PRODUCTION
KEY=your-super-secure-api-key-here
PORT=5001
WEBHOOK_BASE_URL=https://your-webhook-domain.com
```

### 4. PM2 Process Management
```bash
# Create PM2 ecosystem file
cat > ecosystem.config.js << EOF
module.exports = {
  apps: [{
    name: 'wa-gateway',
    script: 'npm',
    args: 'start',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production'
    }
  }]
}
EOF

# Start application
pm2 start ecosystem.config.js

# Save PM2 configuration
pm2 save
pm2 startup
```

### 5. Nginx Reverse Proxy
```nginx
# /etc/nginx/sites-available/wa-gateway
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://localhost:5001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 86400;
    }

    # Media files
    location /media/ {
        alias /path/to/wa-gateway/media/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

```bash
# Enable site
sudo ln -s /etc/nginx/sites-available/wa-gateway /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

### 6. SSL Certificate
```bash
# Install Certbot
sudo apt install certbot python3-certbot-nginx -y

# Get SSL certificate
sudo certbot --nginx -d your-domain.com
```

### 7. Firewall Configuration
```bash
# Configure UFW
sudo ufw allow 22
sudo ufw allow 80
sudo ufw allow 443
sudo ufw enable
```

## 🔒 Security Enhancements

### 1. Secure File Permissions
```bash
# Set proper permissions
chmod 600 .env
chmod 700 wa_credentials/
chmod 755 media/
```

### 2. Backup Strategy
```bash
# Create backup script
cat > backup.sh << EOF
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
tar -czf /backups/wa-gateway-$DATE.tar.gz wa_credentials/ media/ .env
find /backups -name "wa-gateway-*.tar.gz" -mtime +7 -delete
EOF

chmod +x backup.sh

# Add to crontab (daily backup)
echo "0 2 * * * /path/to/backup.sh" | crontab -
```

## 📊 Monitoring

### 1. PM2 Monitoring
```bash
# View logs
pm2 logs wa-gateway

# Monitor performance
pm2 monit

# Restart if needed
pm2 restart wa-gateway
```

### 2. System Resources
```bash
# Monitor resource usage
htop
df -h
free -h
```

## 🚨 Troubleshooting

### Common Issues:
1. **Permission Denied**: Check file permissions for wa_credentials/
2. **Port Already in Use**: Change PORT in .env or kill conflicting process
3. **Memory Issues**: Increase swap or upgrade VPS plan
4. **WhatsApp Session Lost**: Check logs and restart session

### Health Check Endpoint:
```bash
curl -H "key: your-api-key" http://your-domain.com/session
```

## 📈 Scaling Considerations

For high traffic:
- Use nginx load balancing
- Separate media storage (S3/MinIO)
- Database for session management
- Redis for caching
- Multiple VPS instances