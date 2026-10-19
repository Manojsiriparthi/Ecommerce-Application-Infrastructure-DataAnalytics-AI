// Standalone login-path debugger. Prints exactly which step throws.
const { PrismaClient } = require('@prisma/client');
const bcrypt = require('bcryptjs');
const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');
const p = new PrismaClient();

(async () => {
  try {
    console.log('SNS_TOPIC_ARN:', process.env.SNS_TOPIC_ARN || '(not set)');
    console.log('AWS_REGION   :', process.env.AWS_REGION);
    console.log('AWS_ROLE_ARN :', process.env.AWS_ROLE_ARN);

    const u = await p.user.findUnique({ where: { email: 'manoj@test.com' } });
    console.log('user found   :', !!u, '| phone match:', u && u.phone === '9999999999');

    const ok = u && (await bcrypt.compare('Test1234', u.passwordHash));
    console.log('password match:', ok);

    if (process.env.SNS_TOPIC_ARN) {
      const sns = new SNSClient({ region: process.env.AWS_REGION });
      await sns.send(new PublishCommand({
        TopicArn: process.env.SNS_TOPIC_ARN,
        Message: JSON.stringify({ type: 'TEST' }),
      }));
      console.log('SNS publish  : OK');
    }
    console.log('ALL STEPS PASSED');
    process.exit(0);
  } catch (e) {
    console.error('THREW:', e.name, '::', e.message);
    process.exit(1);
  }
})();
