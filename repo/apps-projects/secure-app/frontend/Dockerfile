FROM registry.access.redhat.com/ubi8/nginx-120:1-155

COPY nginx.conf /etc/nginx/nginx.conf
COPY index.html /usr/share/nginx/html/

EXPOSE 8080

USER 1001

CMD ["nginx", "-g", "daemon off;"]









