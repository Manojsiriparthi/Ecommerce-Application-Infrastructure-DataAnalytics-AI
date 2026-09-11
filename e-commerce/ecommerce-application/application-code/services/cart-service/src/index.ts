import 'dotenv/config';import express from 'express';import cors from 'cors';import helmet from 'helmet';import jwt from 'jsonwebtoken';import {PrismaClient} from '@prisma/client';
const app=express(),prisma=new PrismaClient(),port=Number(process.env.PORT||4003),secret=process.env.JWT_SECRET||'dev-secret';app.use(helmet());app.use(cors());app.use(express.json());
function auth(req:any,res:any,next:any){try{const h=req.headers.authorization;if(!h?.startsWith('Bearer '))return res.status(401).json({message:'Unauthorized'});req.user=jwt.verify(h.slice(7),secret);next()}catch{return res.status(401).json({message:'Invalid token'})}}
app.get('/health',(_,r)=>r.json({service:'cart-service',status:'ok'}));
app.get('/api/cart',auth,async(req:any,res)=>{const items=await prisma.cartItem.findMany({where:{userId:req.user.sub},orderBy:{createdAt:'desc'}});res.json({items})});
app.post('/api/cart/items',auth,async(req:any,res)=>{const {productId,quantity,unitPrice}=req.body;if(!productId||Number(quantity)<1||unitPrice===undefined)return res.status(400).json({message:'productId, quantity and unitPrice are required'});const item=await prisma.cartItem.upsert({where:{userId_productId:{userId:req.user.sub,productId}},update:{quantity:{increment:Number(quantity)},unitPrice},create:{userId:req.user.sub,productId,quantity:Number(quantity),unitPrice}});res.status(201).json({item})});
app.patch('/api/cart/items/:id',auth,async(req:any,res)=>{const item=await prisma.cartItem.updateMany({where:{id:req.params.id,userId:req.user.sub},data:{quantity:Number(req.body.quantity)}});res.json({updated:item.count})});
app.delete('/api/cart/items/:id',auth,async(req:any,res)=>{await prisma.cartItem.deleteMany({where:{id:req.params.id,userId:req.user.sub}});res.status(204).send()});
app.delete('/api/cart',auth,async(req:any,res)=>{await prisma.cartItem.deleteMany({where:{userId:req.user.sub}});res.status(204).send()});
app.listen(port,()=>console.log(`cart-service listening on ${port}`));
