import 'dotenv/config';

import express from 'express';
import cors from 'cors';
import helmet from 'helmet';

import {
  SNSClient,
  PublishCommand,
  ConfirmSubscriptionCommand,
} from '@aws-sdk/client-sns';

import {
  SESClient,
  SendEmailCommand,
} from '@aws-sdk/client-ses';

const app = express();

const port = Number(process.env.PORT || 4006);

const awsRegion = process.env.AWS_REGION || 'ap-south-1';

const snsTopicArn = process.env.SNS_TOPIC_ARN;

const sesFromEmail = process.env.SES_FROM_EMAIL;

const snsSmsEnabled = process.env.SNS_SMS_ENABLED === 'true';


// --------------------------------------------------
// AWS clients
// --------------------------------------------------

const sns = new SNSClient({
  region: awsRegion,
});

const ses = new SESClient({
  region: awsRegion,
});


// --------------------------------------------------
// Middleware
// --------------------------------------------------

app.use(helmet());

app.use(cors());

/*
 * SNS HTTP notifications can arrive with different
 * content types, including application/json and
 * text/plain.
 *
 * Therefore we explicitly tell Express to parse both
 * as JSON.
 */
app.use(
  express.json({
    limit: '1mb',
    type: ['application/json', 'text/plain'],
  })
);


// --------------------------------------------------
// Health check
// --------------------------------------------------

app.get('/health', (_req, res) => {
  res.json({
    service: 'notification-service',
    status: 'ok',
  });
});


// --------------------------------------------------
// Message builder
// --------------------------------------------------

function messageFor(event: any): string {
  switch (event.type) {
    case 'USER_LOGIN_SUCCESS':
      return `Hi ${event.name}, login successful. Welcome back!`;

    case 'PAYMENT_SUCCESS':
      return `Your payment ${event.transactionId} was successful.`;

    case 'ORDER_CONFIRMED':
      return `Your order ${event.orderId} has been confirmed.`;

    default:
      return 'You have an update from E-Commerce.';
  }
}


// --------------------------------------------------
// Send SMS
// --------------------------------------------------

async function sendSms(
  phone: string,
  message: string
): Promise<void> {

  if (process.env.SNS_SMS_ENABLED !== 'true') {
    console.log('SMS disabled - skipping SMS');
    return;
  }

  if (!phone) {
    console.log('SMS skipped - phone number missing');
    return;
  }

  console.log(`Sending SMS to ${phone}`);

  await sns.send(
    new PublishCommand({
      PhoneNumber: phone,
      Message: message,
    })
  );

  console.log(`SMS sent to ${phone}`);
}


// --------------------------------------------------
// Send Email
// --------------------------------------------------

async function sendEmail(
  email: string,
  subject: string,
  message: string
): Promise<void> {

  if (!sesFromEmail) {
    console.log('Email skipped - SES_FROM_EMAIL is not configured');
    return;
  }

  if (!email) {
    console.log('Email skipped - recipient email missing');
    return;
  }

  console.log(`Sending email to ${email}`);

  await ses.send(
    new SendEmailCommand({
      Source: sesFromEmail,

      Destination: {
        ToAddresses: [email],
      },

      Message: {
        Subject: {
          Data: subject,
          Charset: 'UTF-8',
        },

        Body: {
          Text: {
            Data: message,
            Charset: 'UTF-8',
          },
        },
      },
    })
  );

  console.log(`Email sent to ${email}`);
}


// --------------------------------------------------
// Process notification event
// --------------------------------------------------

async function processEvent(event: any): Promise<void> {

  if (!event) {
    throw new Error('Notification event is missing');
  }

  if (!event.type) {
    throw new Error('Notification event type is missing');
  }

  console.log(
    'Processing notification event:',
    JSON.stringify(event)
  );

  const message = messageFor(event);

  const results = await Promise.allSettled([
    sendSms(event.phone, message),

    sendEmail(
      event.email,
      'E-Commerce Notification',
      message
    ),
  ]);

  for (const result of results) {
    if (result.status === 'rejected') {
      console.error(
        'Notification delivery failed:',
        result.reason
      );
    }
  }

  console.log(
    `Notification processing completed for event type: ${event.type}`
  );
}


// --------------------------------------------------
// Direct notification event endpoint
// --------------------------------------------------

app.post(
  '/api/notifications/event',
  async (req, res) => {

    try {

      console.log(
        'Direct notification request:',
        JSON.stringify(req.body)
      );

      const event = req.body;

      await processEvent(event);

      return res.status(202).json({
        accepted: true,
      });

    } catch (error) {

      console.error(
        'Notification event processing error:',
        error
      );

      return res.status(500).json({
        message: 'Notification processing failed',
      });
    }
  }
);


// --------------------------------------------------
// SNS HTTP endpoint
// --------------------------------------------------

app.post(
  '/api/notifications/sns',
  async (req, res) => {

    try {

      console.log(
        'SNS request headers:',
        JSON.stringify(req.headers)
      );

      console.log(
        'SNS request body:',
        JSON.stringify(req.body)
      );


      const snsMessage = req.body;

      if (!snsMessage) {
        console.error('SNS request body is empty');

        return res.status(400).send(
          'SNS request body is empty'
        );
      }


      // ------------------------------------------------
      // SNS SubscriptionConfirmation
      // ------------------------------------------------

      if (
        snsMessage.Type === 'SubscriptionConfirmation'
      ) {

        console.log(
          'SNS SubscriptionConfirmation received'
        );

        const topicArn = snsMessage.TopicArn;

        const token = snsMessage.Token;


        if (!topicArn || !token) {

          console.error(
            'SNS confirmation missing TopicArn or Token'
          );

          return res.status(400).send(
            'Invalid SNS confirmation'
          );
        }


        if (
          snsTopicArn &&
          topicArn !== snsTopicArn
        ) {

          console.error(
            'SNS confirmation topic does not match configured topic'
          );

          return res.status(403).send(
            'Invalid SNS topic'
          );
        }


        console.log(
          'Confirming SNS subscription...'
        );


        await sns.send(
          new ConfirmSubscriptionCommand({
            TopicArn: topicArn,
            Token: token,
          })
        );


        console.log(
          'SNS subscription confirmed successfully'
        );


        return res.status(200).send(
          'Subscription confirmed'
        );
      }


      // ------------------------------------------------
      // SNS Notification
      // ------------------------------------------------

      if (
        snsMessage.Type === 'Notification'
      ) {

        console.log(
          'SNS Notification received'
        );


        let event;

        if (
          typeof snsMessage.Message === 'string'
        ) {

          try {

            event = JSON.parse(
              snsMessage.Message
            );

          } catch (parseError) {

            console.error(
              'Failed to parse SNS Message:',
              parseError
            );

            return res.status(400).send(
              'Invalid SNS Message JSON'
            );
          }

        } else {

          event = snsMessage.Message;
        }


        console.log(
          'SNS notification event:',
          JSON.stringify(event)
        );


        await processEvent(event);


        return res.status(200).send('OK');
      }


      // ------------------------------------------------
      // Direct JSON request / testing
      // ------------------------------------------------

      console.log(
        'Unknown SNS message type. Processing as direct event.'
      );


      await processEvent(snsMessage);


      return res.status(200).send('OK');

    } catch (error) {

      console.error(
        'SNS processing error:',
        error
      );

      return res.status(500).send(
        'SNS processing failed'
      );
    }
  }
);


// --------------------------------------------------
// Start service
// --------------------------------------------------

app.listen(
  port,
  () => {
    console.log(
      `notification-service listening on ${port}`
    );

    console.log(
      `AWS region: ${awsRegion}`
    );

    console.log(
      `SNS topic configured: ${snsTopicArn ? 'yes' : 'no'}`
    );

    console.log(
      `SES sender configured: ${sesFromEmail ? 'yes' : 'no'}`
    );

    console.log(
      `SNS SMS enabled: ${snsSmsEnabled ? 'yes' : 'no'}`
    );
  }
);
