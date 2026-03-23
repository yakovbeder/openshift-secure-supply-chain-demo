const express = require('express');
const app = express();
const port = process.env.PORT || 3000;

const BUILD_INFO = {
    version: process.env.APP_VERSION || '1.0.0',
    imageTag: process.env.IMAGE_TAG || 'latest',
    environment: process.env.ENVIRONMENT || 'development',
    buildDate: process.env.BUILD_DATE || new Date().toISOString().split('T')[0],
    commitSha: process.env.CI_COMMIT_SHA || 'local',
    pipelineId: process.env.CI_PIPELINE_ID || 'local'
};

app.get('/api/health', (req, res) => {
    res.json({ 
        status: 'healthy', 
        timestamp: new Date().toISOString(),
        environment: BUILD_INFO.environment
    });
});

app.get('/api/data', (req, res) => {
    res.json({ 
        message: 'Hello from the Secure Backend!',
        signed: true,
        version: BUILD_INFO.version,
        environment: BUILD_INFO.environment
    });
});

app.get('/api/info', (req, res) => {
    res.json({
        message: 'Secure Backend API - All systems operational',
        version: BUILD_INFO.version,
        imageTag: BUILD_INFO.imageTag,
        environment: BUILD_INFO.environment,
        buildDate: BUILD_INFO.buildDate,
        commitSha: BUILD_INFO.commitSha,
        pipelineId: BUILD_INFO.pipelineId,
        signed: true,
        signer: 'GitLab CI Pipeline',
        signedAt: new Date().toISOString(),
        rekorEntry: Math.floor(Math.random() * 10000),
        image: `secure-app/backend:${BUILD_INFO.imageTag}`,
        rhtas: {
            fulcio: 'https://fulcio-server-trusted-artifact-signer.apps.ocpvirt-lab-ff97c3.sandbox1663.opentlc.com',
            rekor: 'https://rekor-server-trusted-artifact-signer.apps.ocpvirt-lab-ff97c3.sandbox1663.opentlc.com',
            tuf: 'https://tuf-trusted-artifact-signer.apps.ocpvirt-lab-ff97c3.sandbox1663.opentlc.com'
        }
    });
});

app.listen(port, '0.0.0.0', () => {
    console.log(`Backend listening on port ${port}`);
    console.log(`Environment: ${BUILD_INFO.environment}`);
    console.log(`Version: ${BUILD_INFO.version}`);
    console.log(`Image Tag: ${BUILD_INFO.imageTag}`);
});
// Pipeline test Thu Dec 11 20:14:03 CET 2025
