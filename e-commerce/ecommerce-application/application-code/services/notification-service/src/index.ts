import 'dotenv/config';
import express from 'express'; import cors from 'cors'; import helmet from 'helmet';
import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';
import { SESClient, SendEmailCommand } from '@aws-sdk/client-ses';
const app=express(), port=Number(process.env.PORT||4006);
const sns=new SNSClient({region:process.env.AWS_REGION||'ap-south-1'});
const ses=new SESClient({region:process.env.AWS_REGION||'ap-south-1'});
app.use(helmet()); app.use(cors()); app.use(express.json({limit:'1mb'}));
app.get('/health',(_,r)=>r.json({service:'notification-service',status:'ok'}));
function messageFor(e:any){switch(e.type){case 'USER_LOGIN_SUCCESS':return `Hi ${e.name}, login successful. Welcome back!`;case 'PAYMENT_SUCCESS':return `Your payment ${e.transactionId} was successful.`;case 'ORDER_CONFIRMED':return `Your order ${e.orderId} has been confirmed.`;default:return 'You have an update from E-Commerce.'}}
async function sendSms(phone:string,message:string){if(!process.env.SNS_SMS_ENABLED)return;await sns.send(new PublishCommand({PhoneNumber:phone,Message:message}))}
async function sendEmail(email:string,subject:string,message:string){if(!process.env.SES_FROM_EMAIL||!email)return;await ses.send(new SendEmailCommand({Source:process.env.SES_FROM_EMAIL,Destination:{ToAddresses:[email]},Message:{Subject:{Data:subject,Charset:'UTF-8'},Body:{Text:{Data:message,Charset:'UTF-8'}}}}))}
app.post('/api/notifications/event',async(req,res)=>{try{const e=req.body;const message=messageFor(e);await Promise.allSettled([sendSms(e.phone,message),sendEmail(e.email,'E-Commerce Notification',message)]);res.status(202).json({accepted:true})}catch{return res.status(500).json({message:'Notification processing failed'})}});
app.post('/api/notifications/sns',async(req,res)=>{try{if(req.body?.Type==='SubscriptionConfirmation')return res.status(200).send('Subscription confirmation received');const raw=typeof req.body?.Message==='string'?JSON.parse(req.body.Message):req.body?.Message;const e=raw||req.body;const message=messageFor(e);await Promise.allSettled([sendSms(e.phone,message),sendEmail(e.email,'E-Commerce Notification',message)]);res.status(200).send('OK')}catch{return res.status(400).send('Invalid SNS message')}});
app.listen(port,()=>console.log(`notification-service listening on ${port}`));
