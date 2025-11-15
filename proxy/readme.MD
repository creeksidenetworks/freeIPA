# Nginx Proxy Manager Configuration for FreeIPA

This document describes how to configure Nginx Proxy Manager (NPM) to reverse proxy FreeIPA.

## Overview

- **FreeIPA Server:** `https://ipa.internal.lcl` (internal)
- **Public URL:** `https://ipa.mycompany.com`
- **FreeIPA Version:** 4.12.2, API Version: 2.254

## Why NPM Requires Special Configuration

Nginx Proxy Manager uses **OpenResty** (nginx with Lua modules) and has a different configuration structure than standard nginx:

1. NPM's template system automatically generates `location /` blocks
2. NPM's `include conf.d/include/proxy.conf` sets default headers that need to be overridden
3. FreeIPA requires the internal hostname in the `Host` header
4. Redirects and URLs must be rewritten from internal to public domain

## Setup Steps in NPM

### 1. Create Proxy Host

In NPM's web interface:

1. Go to **Hosts** → **Proxy Hosts** → **Add Proxy Host**

2. **Details Tab:**
   - **Domain Names:** `ipa.mycompany.com`
   - **Scheme:** `https`
   - **Forward Hostname / IP:** `ipa.internal.lcl`
   - **Forward Port:** `443`
   - ✅ **Block Common Exploits**
   - ✅ **Websockets Support**
   - ⚠️ **CRITICAL: DO NOT enable "Cache Assets"** - This will break sub_filter URL rewriting and cause mixed content errors

3. **SSL Tab:**
   - ✅ Select or request SSL certificate for `ipa.mycompany.com`
   - ✅ **Force SSL**
   - ✅ **HTTP/2 Support**
   - ✅ **HSTS Enabled**

### 2. Advanced Configuration

In the **Advanced** tab, paste the following configuration:

```nginx
# Redirect root to /ipa/ui/ directly from nginx
location = / {
    return 301 https://ipa.mycompany.com/ipa/ui/;
}

location / {
    # CRITICAL: Disable gzip for sub_filter to work
    gzip off;
    
    # Set Host header to internal hostname
    proxy_set_header Host ipa.internal.lcl;
    
    # Other required headers
    proxy_set_header X-Forwarded-Scheme $scheme;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Referer https://ipa.internal.lcl/ipa/ui;
    
    # WebSocket support
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
    proxy_http_version 1.1;
    
    # Cookie domain rewriting
    proxy_cookie_domain ipa.internal.lcl ipa.mycompany.com;
    
    # Timeouts
    proxy_connect_timeout 150;
    proxy_send_timeout 100;
    proxy_read_timeout 100;
    
    # Buffers
    proxy_buffers 4 32k;
    client_max_body_size 200M;
    
    # Proxy pass
    proxy_pass $forward_scheme://$server:$port$request_uri;
    
    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=63072000" always;
}
```

4. **Save** the proxy host


